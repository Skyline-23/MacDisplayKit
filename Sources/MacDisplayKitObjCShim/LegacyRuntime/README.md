# LegacyRuntime

This directory holds imported macOS runtime sources now owned by `MacDisplayKit`.

The files are grouped by subsystem so they can be ported into framework-owned modules in slices:

- `Capture`
- `DisplayRuntime`
- `Input`
- `MetalInterop`
- `Publishing`
- `Support`
- `VirtualDisplay`

These files are intentionally not compiled by the `MacDisplayKitObjCShim` target yet.
They stay here as the framework-owned migration source while Swift APIs and Objective-C++ bridge code are extracted around them.
