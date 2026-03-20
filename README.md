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
  Extraction notes and migration map.
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
