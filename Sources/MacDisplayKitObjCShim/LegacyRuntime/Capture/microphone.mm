/**
 * @file src/platform/macos/microphone.mm
 * @brief Definitions for microphone capture on macOS.
 */
// local includes
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_audio.h"

namespace platf {
  using namespace std::literals;

  namespace {
    bool is_system_audio_sink(std::string sink) {
      std::transform(sink.begin(), sink.end(), sink.begin(), [](unsigned char c) {
        return (char) std::tolower(c);
      });

      return sink.empty()
        || sink == "system"
        || sink == "system audio"
        || sink == "host"
        || sink == "default";
    }

  }  // namespace

  struct av_mic_t: public mic_t {
    AVAudio *av_audio_capture {};

    ~av_mic_t() override {
      [av_audio_capture stopCapture];
      [av_audio_capture release];
    }

    capture_e sample(std::vector<float> &sample_in) override {
      auto sample_size = sample_in.size();

      uint32_t length = 0;
      void *byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);

      while (length < sample_size * sizeof(float)) {
        if (av_audio_capture.captureStopped) {
          return capture_e::interrupted;
        }

        [av_audio_capture.samplesArrivedSignal lock];
        [av_audio_capture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [av_audio_capture.samplesArrivedSignal unlock];

        byteSampleBuffer = TPCircularBufferTail(&av_audio_capture->audioSampleBuffer, &length);
      }

      const float *sampleBuffer = (float *) byteSampleBuffer;
      std::vector<float> vectorBuffer(sampleBuffer, sampleBuffer + sample_size);

      std::copy_n(std::begin(vectorBuffer), sample_size, std::begin(sample_in));

      TPCircularBufferConsume(&av_audio_capture->audioSampleBuffer, sample_size * sizeof(float));

      return capture_e::ok;
    }

    void interrupt() override {
      [av_audio_capture stopCapture];
    }
  };

  struct macos_audio_control_t: public audio_control_t {
    AVCaptureDevice *audio_capture_device {};

  public:
    int set_sink(const std::string &sink) override {
      (void) sink;
      return 0;
    }

    std::unique_ptr<mic_t> microphone(const std::uint8_t *mapping, int channels, std::uint32_t sample_rate, std::uint32_t frame_size) override {
      auto mic = std::make_unique<av_mic_t>();
      const std::string audio_sink = config::audio.sink;

      mic->av_audio_capture = [[AVAudio alloc] init];

      if (is_system_audio_sink(audio_sink)) {
        // Native macOS host-audio capture is still disabled while the kit
        // focuses on stable video acquisition across its default backends.
        BOOST_LOG(warning) << "Temporarily disabling native macOS system audio capture to preserve video cadence."sv;
        return nullptr;
      }

      if ((audio_capture_device = [AVAudio findMicrophone:[NSString stringWithUTF8String:audio_sink.c_str()]]) == nullptr) {
        BOOST_LOG(error) << "opening microphone '"sv << audio_sink << "' failed. Please set a valid input source in the Sunshine config."sv;
        BOOST_LOG(error) << "Available inputs:"sv;

        for (NSString *name in [AVAudio microphoneNames]) {
          BOOST_LOG(error) << "\t"sv << [name UTF8String];
        }

        return nullptr;
      }

      if ([mic->av_audio_capture setupMicrophone:audio_capture_device sampleRate:sample_rate frameSize:frame_size channels:channels]) {
        BOOST_LOG(error) << "Failed to setup microphone."sv;
        return nullptr;
      }

      return mic;
    }

    bool is_sink_available(const std::string &sink) override {
      if (is_system_audio_sink(sink)) {
        return true;
      }

      return [AVAudio findMicrophone:[NSString stringWithUTF8String:sink.c_str()]] != nullptr;
    }

    std::optional<sink_t> sink_info() override {
      sink_t sink;
      sink.host = "System Audio";

      return sink;
    }
  };

  std::unique_ptr<audio_control_t> audio_control() {
    return std::make_unique<macos_audio_control_t>();
  }
}  // namespace platf
