/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
// standard includes
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <strings.h>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/platform/macos/virtual_display.h"
#include "src/process.h"
#include "src/rtsp.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  namespace {
    constexpr double hdr_edr_threshold = 1.001;
    constexpr unsigned int kMaxVirtualDisplayCaptureRestarts = 6;

    NSScreen *screen_for_display_id(CGDirectDisplayID display_id) {
      for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *screen_number = screen.deviceDescription[@"NSScreenNumber"];
        if (screen_number != nil && screen_number.unsignedIntValue == display_id) {
          return screen;
        }
      }

      return nil;
    }

    bool screen_is_hdr_capable(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      if (@available(macOS 10.15, *)) {
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > hdr_edr_threshold
          || screen.maximumExtendedDynamicRangeColorComponentValue > hdr_edr_threshold;
      }

      return false;
    }

    bool screen_is_hdr_active(NSScreen *screen) {
      if (screen == nil) {
        return false;
      }

      if (@available(macOS 10.11, *)) {
        return screen.maximumExtendedDynamicRangeColorComponentValue > hdr_edr_threshold;
      }

      return false;
    }

    bool fallback_hdr_metadata_for_screen(NSScreen *screen, SS_HDR_METADATA &metadata) {
      std::memset(&metadata, 0, sizeof(metadata));
      if (!screen_is_hdr_capable(screen)) {
        return false;
      }

      metadata.displayPrimaries[0] = {34000, 16000};
      metadata.displayPrimaries[1] = {13250, 34500};
      metadata.displayPrimaries[2] = {7500, 3000};
      metadata.whitePoint = {15635, 16450};

      double peak_edr = 1.0;
      if (@available(macOS 10.15, *)) {
        peak_edr = std::max(screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                            screen.maximumExtendedDynamicRangeColorComponentValue);
      }

      const auto estimated_peak_nits = static_cast<uint16_t>(std::clamp(std::lround(peak_edr * 1000.0), 400l, 2000l));
      metadata.maxDisplayLuminance = estimated_peak_nits;
      metadata.maxFullFrameLuminance = estimated_peak_nits;
      metadata.minDisplayLuminance = 1;
      metadata.maxContentLightLevel = estimated_peak_nits;
      metadata.maxFrameAverageLightLevel = estimated_peak_nits;
      return true;
    }

    bool generic_virtual_hdr_metadata(SS_HDR_METADATA &metadata) {
      const auto host_profile = VDISPLAY::probeHostDisplayColorProfile(true, proc::proc.client_display_gamut, proc::proc.client_display_transfer);
      const auto scale = [](double value) -> uint16_t {
        return static_cast<uint16_t>(std::clamp(std::lround(value * 50000.0), 0l, 50000l));
      };

      std::memset(&metadata, 0, sizeof(metadata));
      metadata.displayPrimaries[0] = {scale(host_profile.red.x), scale(host_profile.red.y)};
      metadata.displayPrimaries[1] = {scale(host_profile.green.x), scale(host_profile.green.y)};
      metadata.displayPrimaries[2] = {scale(host_profile.blue.x), scale(host_profile.blue.y)};
      metadata.whitePoint = {scale(host_profile.white.x), scale(host_profile.white.y)};
      metadata.maxDisplayLuminance = 1000;
      metadata.maxFullFrameLuminance = 1000;
      metadata.minDisplayLuminance = 1;
      metadata.maxContentLightLevel = 1000;
      metadata.maxFrameAverageLightLevel = 400;
      return true;
    }

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
    SCCaptureDynamicRange preferred_capture_dynamic_range_for_colorspace(const video::sunshine_colorspace_t &colorspace) {
      if (!video::colorspace_is_hdr(colorspace)) {
        return SCCaptureDynamicRangeSDR;
      }

      if (const char *captureTarget = std::getenv("SUNSHINE_MACOS_HDR_CAPTURE_TARGET"); captureTarget != nullptr) {
        if (strcasecmp(captureTarget, "canonical") == 0) {
          return SCCaptureDynamicRangeHDRCanonicalDisplay;
        }
        if (strcasecmp(captureTarget, "local") == 0 || strcasecmp(captureTarget, "localdisplay") == 0) {
          return SCCaptureDynamicRangeHDRLocalDisplay;
        }
      }

      return SCCaptureDynamicRangeHDRCanonicalDisplay;
    }
#endif

    struct display_capture_context_t {
      const display_t::push_captured_image_cb_t *push_cb;
      const display_t::pull_free_image_cb_t *pull_cb;
    };

    bool materialize_captured_frame(
      std::shared_ptr<img_t> &img_out,
      CMSampleBufferRef sampleBuffer,
      bool map_cpu_memory
    ) {
      auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
      auto new_pixel_buffer_ref = std::make_shared<av_pixel_ref_t>(new_sample_buffer->buf);
      auto av_img = std::static_pointer_cast<av_img_t>(img_out);

      auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
        av_img->sample_buffer,
        av_img->pixel_buffer_ref,
        av_img->pixel_buffer,
        img_out->data
      );

      av_img->sample_buffer = new_sample_buffer;
      av_img->pixel_buffer_ref = new_pixel_buffer_ref;
      img_out->width = (int) CVPixelBufferGetWidth(new_pixel_buffer_ref->buf);
      img_out->height = (int) CVPixelBufferGetHeight(new_pixel_buffer_ref->buf);

      if (map_cpu_memory) {
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_pixel_buffer_ref);
        av_img->pixel_buffer = new_pixel_buffer;
        img_out->data = new_pixel_buffer->data();
        img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer_ref->buf);
        img_out->pixel_pitch = img_out->row_pitch / img_out->width;
      } else {
        av_img->pixel_buffer.reset();
        img_out->data = nullptr;
        img_out->row_pitch = 0;
        img_out->pixel_pitch = 0;
      }

      return true;
    }
  }  // namespace

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};
    bool direct_videotoolbox_frames = false;

    ~av_display_t() override {
      [av_capture release];
    }

    bool is_hdr() override {
      if (proc::proc.virtual_display) {
        return true;
      }
      return screen_is_hdr_active(screen_for_display_id(display_id));
    }

    bool get_hdr_metadata(SS_HDR_METADATA &metadata) override {
      if (proc::proc.virtual_display) {
        return generic_virtual_hdr_metadata(metadata);
      }
      return fallback_hdr_metadata_for_screen(screen_for_display_id(display_id), metadata);
    }

    void interrupt() override {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
      if ([av_capture screenCaptureKitAvailableForDisplay]) {
        [av_capture finishScreenCaptureKitCapture];
        return;
      }
#endif
      if (av_capture.session != nil) {
        [av_capture.session stopRunning];
      }
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
      if ([av_capture screenCaptureKitAvailableForDisplay]) {
        unsigned int restart_attempt = 0;
        while (true) {
          NSError *capture_error = nil;
          if (![av_capture beginScreenCaptureKitCapture:&capture_error]) {
            BOOST_LOG(error) << "Failed to start macOS display capture."sv;
            return capture_e::error;
          }

          bool restart_capture = false;
          while (true) {
            CMSampleBufferRef sampleBuffer = [av_capture copyNextScreenCaptureKitSampleBuffer];
            if (sampleBuffer == nil) {
              auto queued_frames = av_capture.screenCaptureFrameCount;
              if (queued_frames < 60 && restart_attempt < kMaxVirtualDisplayCaptureRestarts) {
                BOOST_LOG(warning) << "ScreenCaptureKit stopped too early (queued_frames="sv << queued_frames
                                   << "); restarting capture attempt "sv << (restart_attempt + 1) << "/"
                                   << kMaxVirtualDisplayCaptureRestarts;
                if (proc::proc.virtual_display) {
                  focus_virtual_display_workspace(display_id);
                }
                restart_capture = true;
              }
              break;
            }

            std::shared_ptr<img_t> img_out;
            if (!pull_free_image_cb(img_out)) {
              CFRelease(sampleBuffer);
              [av_capture finishScreenCaptureKitCapture];
              return capture_e::ok;
            }
            materialize_captured_frame(img_out, sampleBuffer, !direct_videotoolbox_frames);

            const bool keep_capturing = push_captured_image_cb(std::move(img_out), true);
            CFRelease(sampleBuffer);

            if (!keep_capturing) {
              [av_capture finishScreenCaptureKitCapture];
              return capture_e::ok;
            }
          }

          [av_capture finishScreenCaptureKitCapture];
          if (!restart_capture) {
            return capture_e::ok;
          }

          restart_attempt += 1;
          std::this_thread::sleep_for(100ms);
        }
      }
#endif

      auto *capture_context = new display_capture_context_t {
        &push_captured_image_cb,
        &pull_free_image_cb,
      };

      auto signal = [av_capture capture:^bool(CMSampleBufferRef sampleBuffer) {
        std::shared_ptr<img_t> img_out;
        if (!(*capture_context->pull_cb)(img_out)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        materialize_captured_frame(img_out, sampleBuffer, !direct_videotoolbox_frames);

        if (!(*capture_context->push_cb)(std::move(img_out), true)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }

        return true;
      }];

      if (signal == nullptr) {
        delete capture_context;
        BOOST_LOG(error) << "Failed to start macOS display capture."sv;
        return capture_e::error;
      }

      // FIXME: We should time out if an image isn't returned for a while
      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
      delete capture_context;

      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;

        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();

        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat, setCaptureColorspace);

        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        // If we don't have the screen capture permission, this function will hang
        // indefinitely without doing anything useful. Exit instead to avoid this.
        // A non-zero return value indicates failure to the calling function.
        return 1;
      }

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
      if ([av_capture screenCaptureKitAvailableForDisplay]) {
        NSError *capture_error = nil;
        if (![av_capture beginScreenCaptureKitCapture:&capture_error]) {
          BOOST_LOG(error) << "Failed to start macOS dummy capture frame."sv;
          return 1;
        }

        CMSampleBufferRef sampleBuffer = [av_capture copyNextScreenCaptureKitSampleBuffer];
        if (sampleBuffer == nil) {
          [av_capture finishScreenCaptureKitCapture];
          BOOST_LOG(error) << "Failed to receive macOS dummy capture frame."sv;
          return 1;
        }
        std::shared_ptr<img_t> img_out(img, [](img_t *) {});
        materialize_captured_frame(img_out, sampleBuffer, !direct_videotoolbox_frames);

        CFRelease(sampleBuffer);
        [av_capture finishScreenCaptureKitCapture];
        return 0;
      }
#endif

      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer_ref = std::make_shared<av_pixel_ref_t>(new_sample_buffer->buf);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_pixel_buffer_ref);

        auto av_img = (av_img_t *) img;

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer_ref,
          av_img->pixel_buffer,
          img->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer_ref = new_pixel_buffer_ref;
        av_img->pixel_buffer = new_pixel_buffer;
        img->data = new_pixel_buffer->data();

        img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer_ref->buf);
        img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer_ref->buf);
        img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer_ref->buf);
        img->pixel_pitch = img->row_pitch / img->width;

        // returning false here stops capture backend
        return false;
      }];

      if (signal == nullptr) {
        BOOST_LOG(error) << "Failed to start macOS dummy capture frame."sv;
        return 1;
      }

      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return 0;
    }

    /**
     * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
     *
     * display --> an opaque pointer to an object of this class
     * width --> the intended capture width
     * height --> the intended capture height
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }

    static void setCaptureColorspace(void *display, const video::sunshine_colorspace_t &colorspace) {
      auto *av_video = static_cast<AVVideo *>(display);

      switch (colorspace.colorspace) {
        case video::colorspace_e::rec601:
          av_video.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
          av_video.colorSpaceName = kCGColorSpaceITUR_709;
          break;
        case video::colorspace_e::rec709:
          av_video.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
          av_video.colorSpaceName = kCGColorSpaceITUR_709;
          break;
        case video::colorspace_e::bt2020sdr:
          av_video.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          av_video.colorSpaceName = kCGColorSpaceITUR_2020;
          break;
        case video::colorspace_e::bt2020:
          av_video.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
          av_video.colorSpaceName = kCGColorSpaceITUR_2100_PQ;
          break;
      }

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
      if (@available(macOS 15.0, *)) {
        av_video.captureDynamicRange = preferred_capture_dynamic_range_for_colorspace(colorspace);
        BOOST_LOG(info) << "macOS ScreenCaptureKit HDR capture target="
                        << (av_video.captureDynamicRange == SCCaptureDynamicRangeHDRCanonicalDisplay ? "canonical"sv :
                            av_video.captureDynamicRange == SCCaptureDynamicRangeHDRLocalDisplay ? "local"sv :
                                                                                                   "sdr"sv);
      }
#endif
    }
  };

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    auto display = std::make_shared<av_display_t>();
    display->direct_videotoolbox_frames = hwdevice_type == platf::mem_type_e::videotoolbox;

    if (proc::proc.virtual_display &&
        !proc::proc.virtual_display_key.empty() &&
        rtsp_stream::session_count() > 0 &&
        config.width > 0 &&
        config.height > 0 &&
        config.width == proc::proc.client_logical_width &&
        config.height == proc::proc.client_logical_height) {
      const auto logical_width = static_cast<std::uint32_t>(config.width);
      const auto logical_height = static_cast<std::uint32_t>(config.height);
      const auto updated = VDISPLAY::updateVirtualDisplayMode(
        proc::proc.virtual_display_key,
        logical_width,
        logical_height,
        config.encodingFramerate > 0 ? static_cast<std::uint32_t>(config.encodingFramerate) : static_cast<std::uint32_t>(config.framerate),
        config.clientDisplayTransfer
      );
      BOOST_LOG(info) << "macOS virtual display viewport apply logical="sv
                      << logical_width << "x"sv << logical_height
                      << " updated="sv << updated;
    } else if (proc::proc.virtual_display && !proc::proc.virtual_display_key.empty()) {
      BOOST_LOG(info) << "Skipping macOS virtual display viewport apply: session-count="sv
                      << rtsp_stream::session_count()
                      << " config="sv << config.width << "x"sv << config.height
                      << " logical="sv << proc::proc.client_logical_width << "x"sv << proc::proc.client_logical_height
                      << " backing="sv << proc::proc.client_render_width << "x"sv << proc::proc.client_render_height;
    }

    // Default to main display
    display->display_id = CGMainDisplayID();
    bool requested_numeric_display = false;
    if (!display_name.empty()) {
      char *end_ptr = nullptr;
      const auto requested_display_id = std::strtoul(display_name.c_str(), &end_ptr, 10);
      if (end_ptr != nullptr && *end_ptr == '\0' && requested_display_id != 0) {
        display->display_id = static_cast<CGDirectDisplayID>(requested_display_id);
        requested_numeric_display = true;
      }
    }

    // Print all displays available with it's name and id
    auto display_array = [AVVideo displayNames];
    BOOST_LOG(info) << "Detecting displays"sv;
    for (NSDictionary *item in display_array) {
      NSNumber *display_id = item[@"id"];
      // We need show display's product name and corresponding display number given by user
      NSString *name = item[@"displayName"];
      // We are using CGGetActiveDisplayList that only returns active displays so hardcoded connected value in log to true
      BOOST_LOG(info) << "Detected display: "sv << name.UTF8String << " (id: "sv << [NSString stringWithFormat:@"%@", display_id].UTF8String << ") connected: true"sv;
      if (!display_name.empty() && std::atoi(display_name.c_str()) == [display_id unsignedIntValue]) {
        display->display_id = [display_id unsignedIntValue];
      }
    }
    if (requested_numeric_display) {
      BOOST_LOG(info) << "Retaining requested macOS display id ("sv << display->display_id << ") for capture startup"sv;
    }
    BOOST_LOG(info) << "Configuring selected display ("sv << display->display_id << ") to stream"sv;

    display->av_capture = [[AVVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];

    if (!display->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    display->width = display->av_capture.frameWidth;
    display->height = display->av_capture.frameHeight;
    // We also need set env_width and env_height for absolute mouse coordinates
    display->env_width = display->width;
    display->env_height = display->height;

    return display;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> display_names;

    auto display_array = [AVVideo displayNames];

    display_names.reserve([display_array count]);
    [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
      NSNumber *display_id = obj[@"id"];
      if (display_id != nil) {
        display_names.emplace_back(std::to_string(display_id.unsignedIntValue));
        return;
      }

      NSString *name = obj[@"name"];
      if (name != nil) {
        display_names.emplace_back(name.UTF8String);
      }
    }];

    return display_names;
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
