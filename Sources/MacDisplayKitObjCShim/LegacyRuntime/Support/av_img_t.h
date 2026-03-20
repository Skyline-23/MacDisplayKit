/**
 * @file src/platform/macos/av_img_t.h
 * @brief Declarations for AV image types on macOS.
 */
#pragma once

// platform includes
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

// local includes
#include "src/platform/common.h"

namespace platf {
  struct av_sample_buf_t {
    CMSampleBufferRef buf;

    explicit av_sample_buf_t(CMSampleBufferRef buf):
        buf((CMSampleBufferRef) CFRetain(buf)) {
    }

    ~av_sample_buf_t() {
      if (buf != nullptr) {
        CFRelease(buf);
      }
    }
  };

  struct av_pixel_ref_t {
    CVPixelBufferRef buf;

    explicit av_pixel_ref_t(CMSampleBufferRef sb):
        buf((CVPixelBufferRef) CFRetain(CMSampleBufferGetImageBuffer(sb))) {
    }

    explicit av_pixel_ref_t(CVPixelBufferRef pixel_buf):
        buf((CVPixelBufferRef) CFRetain(pixel_buf)) {
    }

    ~av_pixel_ref_t() {
      if (buf != nullptr) {
        CFRelease(buf);
      }
    }
  };

  struct av_pixel_buf_t {
    std::shared_ptr<av_pixel_ref_t> ref;

    explicit av_pixel_buf_t(std::shared_ptr<av_pixel_ref_t> ref):
        ref(std::move(ref)) {
      CVPixelBufferLockBaseAddress(this->ref->buf, kCVPixelBufferLock_ReadOnly);
    }

    [[nodiscard]] uint8_t *data() const {
      return static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(ref->buf));
    }

    ~av_pixel_buf_t() {
      if (ref && ref->buf != nullptr) {
        CVPixelBufferUnlockBaseAddress(ref->buf, kCVPixelBufferLock_ReadOnly);
      }
    }
  };

  struct av_img_t: img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_ref_t> pixel_buffer_ref;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
  };

  struct temp_retain_av_img_t {
    std::shared_ptr<av_sample_buf_t> sample_buffer;
    std::shared_ptr<av_pixel_ref_t> pixel_buffer_ref;
    std::shared_ptr<av_pixel_buf_t> pixel_buffer;
    uint8_t *data;

    temp_retain_av_img_t(
      std::shared_ptr<av_sample_buf_t> sb,
      std::shared_ptr<av_pixel_ref_t> pr,
      std::shared_ptr<av_pixel_buf_t> pb,
      uint8_t *dt
    ):
        sample_buffer(std::move(sb)),
        pixel_buffer_ref(std::move(pr)),
        pixel_buffer(std::move(pb)),
        data(dt) {
    }
  };
}  // namespace platf
