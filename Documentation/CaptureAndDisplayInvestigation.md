# Capture And Display Investigation

This document accumulates reverse-engineering findings gathered while extracting the macOS display and capture runtime into `MacDisplayKit`.

It focuses on two threads:

- virtual display behavior and macOS display-class limits
- ScreenCaptureKit timing and capture cadence behavior

## Current scope

- repo: `MacDisplayKit`
- host app: `MacDisplayKitHost`
- goal: understand what limits high-frequency HDR display capture on macOS and separate policy from mechanism

## Virtual display findings

### HiDPI and Settings UI are separate problems

- `SLVirtualDisplay` can produce a real HiDPI mode where `Resolution != UI Looks Like`.
- That alone does not make macOS show the display in the friendly thumbnail/card-style scaling UI.
- The strongest working hypothesis remains:
  - HiDPI mode selection is one axis
  - display-class / override-backed physical-display classification is a different axis

### The card-style scaling UI likely depends on physical-display classification

Observed evidence:

- external displays with EDID but no override often still show the list UI
- Apple override files commonly carry `scale-resolutions` and `IOGFlags`
- `SLVirtualDisplay` can be made HiDPI, but does not pick up the same display class
- spoofing `vendor/product/name` is not enough to become `built-in` or override-backed

Current interpretation:

- card-style scaling UI appears to depend on an override-backed physical display class
- `SLVirtualDisplay` currently does not expose enough control to reproduce that class

### `displayInfo` is not a free-form override injection surface

Validated constraints:

- `CGVirtualDisplayDescriptor.displayInfo` only exposes a narrow key set
- stable keys include:
  - `DisplayVendorID`
  - `DisplayProductID`
  - `DisplaySerialNumber`
  - color primaries / white point coordinates
- arbitrary override-style keys such as:
  - `scale-resolutions`
  - `IOGFlags`
  - `DisplayPort`
  - `IODisplayEDID`
  were not accepted as a working route

Failure mode:

- invalid `displayInfo` keys can crash `WindowServer`
- crash surfaced through `+[SLVirtualDisplayConfiguration configurationWithDisplayInfo:]`

### Lower-level visible surfaces still did not expose a physical-class setter

Investigated surfaces:

- `SLVirtualDisplayConfiguration`
- `CGVirtualDisplayDescriptor`
- `VirtualDisplayClient`
- `CDVirtualDisplayConnect`
- `CAWindowServerVirtualDisplay`

Outcome:

- identity/control is mostly `vendor/product/serial/displayInfo`
- no working visible API was found that promotes a virtual display into the override-backed physical display class

## Capture findings

### ScreenCaptureKit public trace harness

The host now supports two `SCStream` investigation entry points:

- command:
  - `MacDisplayKitHost --experimental-screencapturekit-timing-display <displayID> --sample-duration <seconds> --json`
  - `MacDisplayKitHost --experimental-screencapturekit-timing-display <displayID> --sample-duration <seconds> --with-metal-stimulus --json`
  - `MacDisplayKitHost --experimental-screencapturekit-proxy-handshake-display <displayID> --sample-duration <seconds> --json`
- output includes:
  - sample buffer arrival delta histogram
  - sample buffer presentation delta histogram
  - unique IOSurface count
  - consecutive IOSurface reuse count
  - IOSurface use-count histogram

Interpretation of the two entry points:

- the timing trace is intentionally public-only and measures the delivery behavior visible through `stream:didOutputSampleBuffer:ofType:`
- the proxy-handshake trace enables private queue tracing and queue-object introspection around the same `SCStream` start path

Important harness bug that was fixed:

- waiting on `startCaptureWithCompletionHandler:` with a semaphore on the main thread starved the run loop
- this produced false negatives with zero samples
- the public trace now pumps the main run loop instead

### Public ScreenCaptureKit trace results

Recent samples on display `2`:

#### 1-second sample

- `sampleBufferEventCount=29`
- arrival deltas clustered around:
  - `~8-10ms`
  - `~54-60ms`
- presentation deltas clustered around:
  - `4.2ms`
  - `8.3ms`
  - `12.5ms`
  - `50-62.5ms`
- `sampleBufferUniqueSurfaceCount=2`
- `sampleBufferConsecutiveSurfaceReuseCount=19`
- `sampleBufferSurfaceUseCountMax=2`

#### 3-second sample

- `sampleBufferEventCount=80`
- effective average delivery over the window: about `26.7 fps`
- arrival deltas:
  - dense `8.3-10ms` cluster
  - dense `50-60ms` cluster
- presentation deltas:
  - `4.2ms`
  - `8.3ms`
  - `12.5ms`
  - `50.0ms`
  - `54.2ms`
  - `58.3ms`
  - `62.5ms`
  - rare `108.3ms`
- `sampleBufferUniqueSurfaceCount=2`
- `sampleBufferConsecutiveSurfaceReuseCount=51`
- `sampleBufferSurfaceUseCountHistogram={"2":53}`

### Interpretation of the current public trace

This does not look like a simple fixed `60 Hz` pipeline.

The stronger interpretation is:

- `SCStream` delivery is not steady high-frequency output
- frames appear to be coalesced or skipped into larger gaps
- surface reuse is aggressive
- the capture cadence is likely shaped by compositor / WindowServer policy rather than encoder throughput

In other words:

- the bottleneck does not currently look like `VideoToolbox`
- the bottleneck does not currently look like Metal processing cost alone
- the bottleneck looks closer to the display/compositor-to-SCStream handoff policy

### What a positive stimulus experiment would mean

If a continuous on-screen animation causes the `~8.3ms` cluster to grow and the `~50-60ms` cluster to shrink, the likely reading is:

- `SCStream` is more change-driven than steady-refresh-driven in this configuration
- compositor activity materially affects delivery cadence
- the problem is not “Metal is slow”
- the problem is “the public capture handoff is not delivering every compositor tick”

That would strengthen the case for:

- direct surface/queue consumption below the public `SCStream` layer
- or a different capture path entirely

It would not, by itself, prove that “Metal fixes capture.”

Metal can help with:

- processing
- color conversion
- scaling
- compositing

Metal cannot by itself replace the OS-level screen frame source.

### Metal stimulus follow-up

The host now supports a full-screen Metal stimulus window during the public timing trace:

- command:
  - `MacDisplayKitHost --experimental-screencapturekit-timing-display <displayID> --sample-duration <seconds> --with-metal-stimulus --json`

The stimulus itself is intentionally simple:

- a borderless full-screen `MTKView`
- preferred `120 fps`
- animated clear-color only
- no extra compositing or scene complexity beyond forcing visible continuous motion

Recent `3`-second comparison on display `2`:

#### Idle trace

- `sampleBufferEventCount=79`
- arrival deltas at `<=12.5ms`: `30`
- arrival deltas at `45-70ms`: `48`
- presentation deltas at `<=12.5ms`: `38`
- presentation deltas at `45-70ms`: `33`
- `sampleBufferUniqueSurfaceCount=2`
- `sampleBufferConsecutiveSurfaceReuseCount=67`

#### Full-screen Metal stimulus trace

- `sampleBufferEventCount=78`
- arrival deltas at `<=12.5ms`: `27`
- arrival deltas at `45-70ms`: `49`
- presentation deltas at `<=12.5ms`: `34`
- presentation deltas at `45-70ms`: `36`
- `sampleBufferUniqueSurfaceCount=5`
- `sampleBufferConsecutiveSurfaceReuseCount=10`

Interpretation:

- the stimulus clearly changes the surface rotation pattern
- however it does not materially collapse the `45-70ms` gap cluster
- that weakens the simple “static scenes are the only problem” reading
- it strengthens the reading that the limiting policy sits closer to WindowServer / compositor cadence than to a pure change-detection heuristic in the public trace consumer

## Private capture findings

### One-shot private hardware capture

Validated:

- `CGSHWCaptureDisplayIntoIOSurfaceWithOptions`
- single-frame capture can succeed

Observed benchmark:

- direct repeated one-shot calls only produced about `3.8-3.9 fps`

Interpretation:

- this is not likely the intended fast path
- a stream/proxy/session precondition is probably missing

### Proxy handshake and private-queue tracing

The host also traces internal queue handoff behavior around `SCStream`.

Observed:

- `SCRemoteQueueXPCObject` and queue payloads are real and carry:
  - shared memory region
  - queue offset
  - send/recv fds
  - `IOSurfaceReceiver`
- video queue setup is the critical path
- timing of `IOSurfaceReceiver` consumption matters

The current host-only proxy trace records:

- `SCRemoteQueueXPCObject` setup and `queueType` changes
- captured replayd queue payloads, including:
  - shared memory region
  - queue offset
  - send/recv fds
  - `IOSurfaceReceiver`
- `SCRemoteQueue_CreateReceiverQueue` wrapper attach results
- `FigRemoteQueueReceiver` attach results
- delivery-comparison fields:
  - `firstPrivateQueueSource`
  - `firstPrivateQueueTimestampNanos`
  - `firstPublicSampleTimestampNanos`
  - `privateQueueLeadMilliseconds`
  - `surfacePointerMatched`

Current important caveat:

- the host intentionally skips `stopCaptureWithCompletionHandler:` in this trace because the stop path currently triggers an `RPDaemonProxy` `NSXPCEncoder` exception

Current important failure mode:

- enabling the current consuming private queue probes can leave `sampleBufferEventCount=0`
- in that same state, the post-start `videoQueueEntry` often shows `IOSurfaceReceiver` as `(consumed)`
- current interpretation: the active probe path is stealing the receive right before public `SCStream` sample delivery begins

This line of work remains useful for finding a lower-level capture consumer, but it is not yet a performance path by itself.

## External clues worth keeping in mind

- Apple Developer Forums:
  - `virtual display + ScreenCaptureKit` issues continue to surface and DTS has treated some reports as bugworthy
  - https://developer.apple.com/forums/thread/786829
- OBS issues:
  - macOS screen capture behavior above `60 fps` has been problematic enough to require dedicated fixes
  - https://github.com/obsproject/obs-studio/issues/10636
  - https://github.com/obsproject/obs-studio/issues/11778
- Nonstrict notes:
  - public `SCStream` behavior is not a perfect “always stream every frame” source
  - https://nonstrict.eu/blog/2023/a-mac-tastic-indie-adventure
- Stack Overflow discussion on `ScreenCaptureKit` latency and cadence:
  - https://stackoverflow.com/questions/79718758/why-is-screencapturekit-frame-capture-delayed-by-more-than-16ms-at-60-fps

## Current working hypotheses

### H1

`SCStream` cadence is strongly shaped by compositor / WindowServer delivery policy and not just by `minimumFrameInterval`.

### H2

The public capture path is coalescing or skipping updates instead of behaving like a clean steady `120 Hz` source.

### H3

A lower-level surface/queue consumer may recover more of the compositor cadence than the public `SCStream` output layer.

### H4

Virtual display card-style scaling UI remains blocked on physical-display classification, not on HiDPI mode availability.

## Next experiments

1. Move below the public `SCStream` consumer and keep tracing queue/surface transport behavior.
2. Correlate public timing traces with WindowServer/compositor activity instead of assuming static-scene coalescing is the dominant cause.
3. If a lower-level queue consumer still shows the same `45-70ms` gap cluster, treat compositor cadence policy as the primary ceiling.
4. Keep the virtual display UI/classification track separate from the capture-cadence track.
