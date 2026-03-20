/**
 * @file src/platform/macos/vt_metal_context.h
 * @brief Declarations for the Metal-backed VideoToolbox frame preparation path on macOS.
 */
#pragma once

#include <CoreVideo/CoreVideo.h>

#include <memory>

namespace platf {
  class vt_metal_context_t {
  public:
    vt_metal_context_t();
    ~vt_metal_context_t();

    [[nodiscard]] bool valid() const;
    bool prepare_pixel_buffer(CVPixelBufferRef pixel_buffer);

  private:
    struct impl_t;
    std::unique_ptr<impl_t> impl;
  };
}  // namespace platf
