/**
 * @file src/platform/macos/vt_metal_context.mm
 * @brief Definitions for the Metal-backed VideoToolbox frame preparation path on macOS.
 */
#import <Metal/Metal.h>

#include "src/platform/macos/vt_metal_context.h"

namespace platf {
  struct vt_metal_context_t::impl_t {
    id<MTLDevice> device {nil};
    id<MTLCommandQueue> command_queue {nil};
    CVMetalTextureCacheRef texture_cache {nullptr};

    impl_t() {
      device = MTLCreateSystemDefaultDevice();
      if (device == nil) {
        return;
      }

      command_queue = [device newCommandQueue];
      if (command_queue == nil) {
        return;
      }

      CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, &texture_cache);
    }

    ~impl_t() {
      if (texture_cache != nullptr) {
        CFRelease(texture_cache);
        texture_cache = nullptr;
      }
      [command_queue release];
      command_queue = nil;
      [device release];
      device = nil;
    }

    [[nodiscard]] bool valid() const {
      return device != nil && command_queue != nil && texture_cache != nullptr;
    }

    bool prepare_pixel_buffer(CVPixelBufferRef pixel_buffer) {
      if (!valid() || pixel_buffer == nullptr) {
        return false;
      }

      const OSType pixel_format = CVPixelBufferGetPixelFormatType(pixel_buffer);
      const size_t plane_count = CVPixelBufferIsPlanar(pixel_buffer) ? (size_t) CVPixelBufferGetPlaneCount(pixel_buffer) : 1;
      CVMetalTextureRef textures[2] = {nullptr, nullptr};

      auto release_textures = [&]() {
        for (auto &texture : textures) {
          if (texture != nullptr) {
            CFRelease(texture);
            texture = nullptr;
          }
        }
      };

      bool prepared = false;
      switch (pixel_format) {
        case kCVPixelFormatType_32BGRA:
          prepared = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            texture_cache,
            pixel_buffer,
            nullptr,
            MTLPixelFormatBGRA8Unorm,
            CVPixelBufferGetWidth(pixel_buffer),
            CVPixelBufferGetHeight(pixel_buffer),
            0,
            &textures[0]
          ) == kCVReturnSuccess;
          break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
          prepared =
            plane_count >= 2 &&
            CVMetalTextureCacheCreateTextureFromImage(
              kCFAllocatorDefault,
              texture_cache,
              pixel_buffer,
              nullptr,
              MTLPixelFormatR8Unorm,
              CVPixelBufferGetWidthOfPlane(pixel_buffer, 0),
              CVPixelBufferGetHeightOfPlane(pixel_buffer, 0),
              0,
              &textures[0]
            ) == kCVReturnSuccess &&
            CVMetalTextureCacheCreateTextureFromImage(
              kCFAllocatorDefault,
              texture_cache,
              pixel_buffer,
              nullptr,
              MTLPixelFormatRG8Unorm,
              CVPixelBufferGetWidthOfPlane(pixel_buffer, 1),
              CVPixelBufferGetHeightOfPlane(pixel_buffer, 1),
              1,
              &textures[1]
            ) == kCVReturnSuccess;
          break;
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
          prepared =
            plane_count >= 2 &&
            CVMetalTextureCacheCreateTextureFromImage(
              kCFAllocatorDefault,
              texture_cache,
              pixel_buffer,
              nullptr,
              MTLPixelFormatR16Unorm,
              CVPixelBufferGetWidthOfPlane(pixel_buffer, 0),
              CVPixelBufferGetHeightOfPlane(pixel_buffer, 0),
              0,
              &textures[0]
            ) == kCVReturnSuccess &&
            CVMetalTextureCacheCreateTextureFromImage(
              kCFAllocatorDefault,
              texture_cache,
              pixel_buffer,
              nullptr,
              MTLPixelFormatRG16Unorm,
              CVPixelBufferGetWidthOfPlane(pixel_buffer, 1),
              CVPixelBufferGetHeightOfPlane(pixel_buffer, 1),
              1,
              &textures[1]
            ) == kCVReturnSuccess;
          break;
        default:
          prepared = false;
          break;
      }

      release_textures();
      CVMetalTextureCacheFlush(texture_cache, 0);
      return prepared;
    }
  };

  vt_metal_context_t::vt_metal_context_t():
      impl(std::make_unique<impl_t>()) {
  }

  vt_metal_context_t::~vt_metal_context_t() = default;

  bool vt_metal_context_t::valid() const {
    return impl && impl->valid();
  }

  bool vt_metal_context_t::prepare_pixel_buffer(CVPixelBufferRef pixel_buffer) {
    return impl && impl->prepare_pixel_buffer(pixel_buffer);
  }
}  // namespace platf
