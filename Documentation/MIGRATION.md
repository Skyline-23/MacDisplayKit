# Migration Map

## Goal

Move an existing macOS display and capture runtime into `MacDisplayKit` in small slices while keeping downstream integration minimal.

## Imported Source Root

The current imported legacy runtime lives under:

- `Sources/MacDisplayKitObjCShim/LegacyRuntime`
- `Tools/LegacyRuntime`

The owning repository is now `MacDisplayKit`. The remaining work is compilation and API extraction, not source ownership transfer.

## Planned Framework Surface

### Public API

- virtual display specification and lifecycle
- capture configuration
- backend selection
- framework diagnostics and capabilities
- Swift-owned orchestration surface

### Public Modules

- `MacDisplayCaptureKit`
  Optional consumer-facing capture types.
- `MacDisplayVirtualDisplayKit`
  Optional consumer-facing virtual display lifecycle types.
- `MacDisplayKit`
  Umbrella target that re-exports the capability modules.

### Internal Modules

- `VirtualDisplay`
  `virtual_display.mm`, display identity, mode, HDR metadata
- `Capture`
  `av_video.m`, `av_audio.m`, `microphone.mm`
- `DisplayRuntime`
  `display.mm`, `misc.mm`
- `MetalInterop`
  `vt_metal_context.mm`, `nv12_zero_device.cpp`
- `ObjCShim`
  private framework and C++ bridge surface consumed by Swift
- `LegacyRuntime`
  imported source tree organized into `Capture`, `DisplayRuntime`, `VirtualDisplay`, `MetalInterop`, `Input`, `Publishing`, and `Support`

## Transitional App Strategy

The extraction uses two app targets:

- `MacDisplayKitLegacyHost`
  Runs against the imported legacy macOS implementation with as little rewriting as possible.
- `MacDisplayKitHost`
  Runs against the framework surface only and acts as the clean-room destination.

This keeps performance and private-API experiments out of consumer repositories while still allowing stepwise migration.

## Responsibility Boundary

`MacDisplayKit` owns:

- virtual display lifecycle
- display mode and HDR metadata management
- capture backend selection and frame acquisition
- macOS-only diagnostics and capability probing
- Swift-first API design
- Objective-C++ and Metal interop shims

Consumer apps own:

- transport protocol details
- session orchestration
- app-specific negotiation and policy
- mapping app session state into `MacDisplayKit` inputs

## Current Coupling To Legacy Runtime

These legacy headers currently block a direct move:

- `src/config.h`
- `src/logging.h`
- `src/platform/common.h`
- `src/process.h`
- `src/video.h`
- `src/rtsp.h`
- `src/display_device.h`
- `src/network.h`
- `src/nvhttp.h`
- `src/input.h`
- `src/entry_handler.h`
- `src/utility.h`

## Migration Order

1. Stabilize the public framework API.
2. Stand up `MacDisplayKitLegacyHost` with compatibility shims for logging, config, and session state.
3. Port virtual display code into framework-owned modules.
4. Port capture code.
5. Port remaining platform glue.
6. Replace direct macOS implementation in consumer apps with a framework adapter.
