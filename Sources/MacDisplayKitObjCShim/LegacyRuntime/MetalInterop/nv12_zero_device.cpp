/**
 * @file src/platform/macos/nv12_zero_device.cpp
 * @brief Definitions for NV12 zero copy device on macOS.
 */
// standard includes
#include <utility>

// local includes
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/video.h"

extern "C" {
#include "libavutil/imgutils.h"
}

namespace platf {
  namespace {
    OSType cv_pixel_format_for_config(pix_fmt_e pix_fmt, bool full_range) {
      if (pix_fmt == pix_fmt_e::nv12) {
        return full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      }

      return full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    }

  }  // namespace

  void free_frame(AVFrame *frame) {
    av_frame_free(&frame);
  }

  void free_buffer(void *opaque, uint8_t *data) {
    CVPixelBufferRelease((CVPixelBufferRef) data);
  }

  int nv12_zero_device::convert(platf::img_t &img) {
    auto *av_img = (av_img_t *) &img;
    if (!this->frame || !av_img->pixel_buffer_ref || !av_img->pixel_buffer_ref->buf) {
      return -1;
    }

    // Release any existing CVPixelBuffer previously retained for encoding
    av_buffer_unref(&this->frame->buf[0]);

    // Attach an AVBufferRef to this frame which will retain ownership of the CVPixelBuffer
    // until av_buffer_unref() is called (above) or the frame is freed with av_frame_free().
    //
    // The presence of the AVBufferRef allows FFmpeg to simply add a reference to the buffer
    // rather than having to perform a deep copy of the data buffers in avcodec_send_frame().
    this->frame->buf[0] = av_buffer_create((uint8_t *) CFRetain(av_img->pixel_buffer_ref->buf), 1, free_buffer, nullptr, 0);

    // Place a CVPixelBufferRef at data[3] as required by AV_PIX_FMT_VIDEOTOOLBOX
    this->frame->data[3] = this->frame->buf[0]->data;

    return 0;
  }

  int nv12_zero_device::set_frame(AVFrame *frame, AVBufferRef *hw_frames_ctx) {
    this->frame = frame;

    resolution_fn(this->display, frame->width, frame->height);

    return 0;
  }

  int nv12_zero_device::init(void *display, pix_fmt_e pix_fmt, resolution_fn_t resolution_fn, const pixel_format_fn_t &pixel_format_fn, const colorspace_fn_t &colorspace_fn) {
    this->display = display;
    this->pixel_format = pix_fmt;
    this->resolution_fn = std::move(resolution_fn);
    this->pixel_format_fn = pixel_format_fn;
    this->colorspace_fn = colorspace_fn;
    pixel_format_fn(display, cv_pixel_format_for_config(pix_fmt, false));

    // we never use this pointer, but its existence is checked/used
    // by the platform independent code
    data = this;

    return 0;
  }

  void nv12_zero_device::apply_colorspace() {
    pixel_format_fn(display, cv_pixel_format_for_config(pixel_format, colorspace.full_range));
    colorspace_fn(display, colorspace);
  }

}  // namespace platf
