# MacDisplayKit

`MacDisplayKit` is a reusable macOS display and capture framework umbrella.

The immediate goal of this repository is to keep macOS-only display, capture, HDR, and virtual-display work in a standalone module so that:

- downstream apps can consume only the display and capture capabilities they need.
- private-API and performance work can iterate in a separate repo.
- framework responsibilities stay separate from transport and session policy.

## Current State

This repository currently contains:

- Tuist-generated macOS framework targets
- a Swift-first public surface backed by Objective-C++ shims
- a legacy host app target for imported macOS runtime experiments
- a clean host app target for framework-only validation
- a Swift Package manifest for downstream consumption
- an imported legacy runtime source tree for incremental porting
- a production raw `SkyLight` capture session surface
- a production encoded capture session surface backed by Metal + VideoToolbox

The imported legacy runtime is intentionally not wired into the framework target yet. The first step is to stabilize the boundary: Swift owns framework-facing orchestration and API shape, while Objective-C++ remains the bridge for C++, private frameworks, and Metal-backed interop.

Imported legacy runtime sources now live inside the repository-owned `Sources/MacDisplayKitObjCShim/LegacyRuntime` tree. They are source-owned by `MacDisplayKit`, but they are still ported into build targets in controlled slices rather than all at once.

## Repository Layout

- `Sources/MacDisplayCaptureKit`
  Capture-facing public API that can be consumed without virtual display support.
- `Sources/MacDisplayVirtualDisplayKit`
  Virtual display lifecycle API built on top of the Objective-C++ shim.
- `Sources/MacDisplayKit`
  Umbrella surface that re-exports the capability modules.
- `Sources/MacDisplayKitObjCShim`
  Objective-C++ bridge layer for private API, C++, and Metal interop.
- `Sources/MacDisplayKitObjCShim/LegacyRuntime`
  Framework-owned imported macOS runtime sources, organized by subsystem for incremental porting.
- `Sources/MacDisplayKitLegacyHost`
  Transitional macOS host app for imported runtime experiments.
- `Sources/MacDisplayKitHost`
  Minimal macOS host app used to validate framework integration.
- `Tests/MacDisplayKitTests`
  Lightweight framework tests.
- `Documentation`
  Investigation notes and migration map.
  Start with [`Documentation/CaptureAndDisplayInvestigation.md`](Documentation/CaptureAndDisplayInvestigation.md)
  for the current encoded-capture findings and optimization direction.
- `Tools/LegacyRuntime`
  Runtime introspection and reverse-engineering helpers.

## Development

Generate the Xcode workspace:

```bash
tuist generate --no-open
```

Build the host app:

```bash
xcodebuild build \
  -workspace MacDisplayKit.xcworkspace \
  -scheme MacDisplayKitHost \
  -configuration Debug
```

Run the Swift package tests:

```bash
swift test
```

## Production Capture Surface

`MacDisplayCaptureKit` now exposes two non-benchmark session layers:

- `MDKSkyLightDisplayStreamSession`
  - raw `SkyLight` frame delivery backed by `SLDisplayStream`
  - panel-native sizing by default
  - intended for apps that want direct `IOSurface` access
- `MDKEncodedCaptureSession`
  - raw `SkyLight` capture + Metal preprocessing + VideoToolbox encode
  - direct callback consumer interface via `MDKEncodedCaptureCallbacks`
  - `AsyncThrowingStream<MDKEncodedFrame, Error>` stream consumer interface
  - `AsyncStream<MDKEncodedCaptureSessionEvent>` lifecycle/recovery/backpressure events
  - `baseline-q2` raw queue profile by default
  - backpressure via stream buffering policy when the stream consumer path is used
  - automatic restart policy for capture/processing failures

The encoded session currently supports:

- `HEVC Main10`
- `H.264`
- `ProRes Proxy` as a quality-oriented option for desktop/UI capture, biased toward `BGRA` capture surfaces for desktop/UI fidelity

Canonical external codec identifiers are:

- `hevc`
- `h264`
- `prores-proxy`

HDR signaling support is wired into the production encode path through:

- `kVTCompressionPropertyKey_ColorPrimaries`
- `kVTCompressionPropertyKey_TransferFunction`
- `kVTCompressionPropertyKey_YCbCrMatrix`
- `kVTCompressionPropertyKey_HDRMetadataInsertionMode`
- mastering-display and content-light metadata payloads

Validation caveat:

- this repository can now emit HDR-signaled HEVC Main10 samples when given HDR configuration
- `MDKEncodedFrame.hdrValidationReport` exposes the encoded bitstream signaling that the framework can verify in-process
- host-side production diagnostics have validated BT.2020/PQ signaling, mastering-display metadata, and content-light metadata on encoded session output
- a real HDR monitor is still required to validate end-to-end source HDR capture behavior

Throughput note:

- the callback consumer path is the preferred high-throughput integration surface for downstream apps
- the stream consumer path remains available, but it is not the current throughput winner for 4K120-class workloads

## Module Boundary

Consumers that only need capture should depend on `MacDisplayCaptureKit`.

Consumers that need virtual display creation should add `MacDisplayVirtualDisplayKit`.

Consumers that want a single umbrella import can use `MacDisplayKit`.

## Responsibility Boundary

`MacDisplayKit` owns:

- virtual display lifecycle
- display mode and HDR metadata
- capture backend selection
- frame acquisition and diagnostics
- Metal and Objective-C++ interop shims

Consumer apps own:

- transport protocol
- session orchestration
- pairing and authentication
- app-specific policy
- mapping app state into `MacDisplayKit` inputs
