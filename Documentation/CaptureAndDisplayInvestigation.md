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
  - `MacDisplayKitHost --experimental-screencapturekit-passive-handshake-display <displayID> --sample-duration <seconds> --json`
  - `MacDisplayKitHost --experimental-screencapturekit-proxy-handshake-display <displayID> --sample-duration <seconds> --json`
- output includes:
  - sample buffer arrival delta histogram
  - sample buffer presentation delta histogram
  - unique IOSurface count
  - consecutive IOSurface reuse count
  - IOSurface use-count histogram

Interpretation of the two entry points:

- the timing trace is intentionally public-only and measures the delivery behavior visible through `stream:didOutputSampleBuffer:ofType:`
- the passive handshake trace records the same queue setup milestones as the proxy handshake trace, but does not prime any private queue wrapper or `FigRemoteQueueReceiver`
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

### Public timing cadence classification

The public timing trace now derives coarse cadence classifications directly from the
arrival and presentation delta histograms:

- `120hz-like`
- `60hz-like`
- `coalesced-or-mixed`
- `mixed-or-transitional`
- `insufficient-data`

Recent `3`-second run on display `2`:

#### Idle public timing trace

- `sampleBufferEventCount=86`
- `sampleBufferArrivalDelta120HzEquivalentCount=35 / 85`
- `sampleBufferArrivalCadenceClassification=coalesced-or-mixed`
- `sampleBufferPresentationDelta120HzEquivalentCount=31 / 85`
- `sampleBufferPresentationCadenceClassification=coalesced-or-mixed`

#### Full-screen Metal stimulus public timing trace

- `sampleBufferEventCount=87`
- `sampleBufferArrivalDelta120HzEquivalentCount=33 / 86`
- `sampleBufferArrivalCadenceClassification=coalesced-or-mixed`
- `sampleBufferPresentationDelta120HzEquivalentCount=35 / 86`
- `sampleBufferPresentationCadenceClassification=coalesced-or-mixed`

Interpretation:

- the public `SCStream` path does produce some `~8.3ms`-class deltas
- however those deltas are not dominant under either idle or continuous visible motion
- the path does not sustain a `120hz-like` cadence classification in this configuration
- the remaining work should target the handoff below public sample delivery rather than more tuning of the public callback path

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
- `firstPublicSamplePrecedingEventKind`
- `firstPublicSamplePrecedingEventLeadMilliseconds`
- `firstPublicSamplePrecedingStateSourceKind`
- `firstPublicSamplePrecedingStateLeadMilliseconds`
- `firstPublicSampleLastVideoEventKind`
- `firstPublicSampleLastVideoEventLeadMilliseconds`
- `firstPublicSampleInterveningEventKinds`
  - `privateQueueLeadMilliseconds`
  - `surfacePointerMatched`

Current important caveat:

- the host intentionally skips `stopCaptureWithCompletionHandler:` in this trace because the stop path currently triggers an `RPDaemonProxy` `NSXPCEncoder` exception

Current important failure mode:

- enabling the current consuming private queue probes can leave `sampleBufferEventCount=0`
- in that same state, the post-start `videoQueueEntry` often shows `IOSurfaceReceiver` as `(consumed)`
- current interpretation: the active probe path is stealing the receive right before public `SCStream` sample delivery begins

This line of work remains useful for finding a lower-level capture consumer, but it is not yet a performance path by itself.

### Passive handshake tracing

The host now exposes the same handshake/startup path without the consuming private queue probes:

- command:
  - `MacDisplayKitHost --experimental-screencapturekit-passive-handshake-display <displayID> --sample-duration <seconds> --json`

Interpretation:

- this mode still records:
  - `startCapture:withContentFilter:...`
  - remote queue setup
  - `SCRemoteQueueXPCObject` classification
  - public sample delivery
- but it does not call:
  - `SCRemoteQueue_CreateReceiverQueue`
  - `FigRemoteQueueReceiverCreateFromXPCObject`
- this is the safe bridge between:
  - queue/setup discovery
  - public `stream:didOutputSampleBuffer:ofType:`
- it now also reports which event immediately preceded the first healthy public sample, plus the nearest earlier `streamState` snapshot if the immediate predecessor had no state

Current use:

- use the passive handshake trace when the goal is to connect queue setup to the first healthy public sample without consuming the `IOSurfaceReceiver` mach right
- use the consuming proxy-handshake trace only when the goal is to inspect receiver creation behavior itself

Recent passive-handshake sample on display `2`:

- `sampleBufferEventCount=39`
- public `stream:didOutputSampleBuffer:ofType:` delivery remained healthy
- the same run still did not observe `RPDaemonProxy proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:`

Recent passive-handshake sample after adding predecessor derivation on display `2`:

- `sampleBufferEventCount=39`
- immediate predecessor event kind: `stream-start-remote-microphone-receive-queue`
- immediate predecessor lead: `16.5595 ms`
- last video-path event kind: `stream-post-start-remote-video-state`
- last video-path lead: `16.898625 ms`
- nearest earlier state source: `stream-post-start-remote-video-state`
- nearest earlier state lead: `16.898625 ms`
- intervening event kinds:
  - `sc-remote-queue-set-remote-queue`
  - `start-remote-queue`
  - `manager-start-remote-queue`
  - `stream-start-remote-receive-queue`
  - `stream-start-remote-audio-receive-queue`
  - `sc-remote-queue-set-remote-queue`
  - `start-remote-queue`
  - `manager-start-remote-queue`
  - `stream-start-remote-receive-queue`
  - `stream-start-remote-microphone-receive-queue`

Interpretation:

- queue setup and public sample delivery can be correlated in one healthy session without consuming the queue
- `proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:` is not required for the public sample path we are currently observing
- the next useful split is no longer “can we keep public samples alive,” but “which earlier queue/setup transition best predicts the first healthy sample”
- in the current trace, the first public sample lands about `16.9 ms` after the last video-path event, with audio and microphone remote-queue startup noise interleaved in between

### Runtime inventory after forcing ScreenCaptureKit into the global runtime

The host now exposes a runtime inventory command:

- command:
  - `MacDisplayKitHost --experimental-screencapturekit-runtime-inventory --json`

Recent sample after forcing `ScreenCaptureKit.framework` into the global runtime with `RTLD_GLOBAL`:

- loaded classes:
  - `SCStream`
  - `SCStreamManager`
  - `SCRemoteQueueXPCObject`
  - `RPDaemonProxy`
  - `BWRemoteQueueSinkNode`
  - `FigCaptureRemoteQueueSinkPipeline`
- present private C symbols:
  - `SCRemoteQueue_CreateReceiverQueue`
  - `SCRemoteQueue_UpdateReceiverQueue`
  - `SCRemoteQueue_Destroy`
- absent guessed queue-consumption helpers:
  - `SCRemoteQueue_Dequeue`
  - `SCRemoteQueue_Drain`
  - `SCRemoteQueue_Resume`
  - `SCRemoteQueue_Start`
  - `SCRemoteQueue_StartReceiving`
- present CMCapture helpers:
  - `FigRemoteQueueReceiverCreateFromXPCObject`
  - `FigRemoteQueueReceiverDequeue`
  - `FigRemoteQueueReceiverSetHandler`
  - `FigRemoteQueueReceiverUnsetHandler`

Interpretation:

- the runtime inventory is now trustworthy enough to drive selector choice for new swizzles
- the obvious missing piece is still the actual on-path queue-consumption handoff
- there is no exposed private C “resume/start/drain” helper to call directly

### Lower-path reality check on the healthy public sample path

Recent passive-handshake sample on display `2`:

- `sampleBufferEventCount=53`
- `rpIOSurfaceEventCount=0`
- `captureHandlerSampleEventCount=0`
- `contentStreamEventCount=0`
- `surfaceTransportEventCount=0`
- `frameReceiverEventCount=0`
- `remoteQueueSinkEventCount=0`
- `remoteQueueObjectEventCount=3`
- `BWRemoteQueueSinkNode` and `FigCaptureRemoteQueueSinkPipeline` were both present in the runtime, but neither emitted events on this healthy path

Interpretation:

- the currently healthy public `SCStream` path is not going through the lower candidates we first expected
- `BWRemoteQueueSinkNode`, `RPIOSurface`, `CAContentStream`, `IOSurfaceRemoteRemoteClient`, and `CMCaptureFrameReceiver` are currently dead ends for this trace
- the private `videoReceiveQueueWrapper` callback block is still structurally interesting, but blind replacement is not safe enough to keep using as the next probe
- current wrapper signature in the video queue snapshot:
  - `v28@?0i8^{FigRemoteQueueMessage=^v^{__IOSurface}i}12^v20`

### Passive lower-path observation without consuming the queue

The passive handshake trace now does two read-only lower-level observations during a healthy public `SCStream` session:

- polls the video queue `SharedRegion` mapping from `SCRemoteQueueXPCObject.remoteQueue`
- duplicates `RecvFd` from the same XPC dictionary and polls readiness / `FIONREAD` without reading from it

Recent idle sample on display `2` for `3s`:

- public sample presentation histogram:
  - `{"4.2ms":1,"8.3ms":3,"16.7ms":3,"50.0ms":1,"54.2ms":1,"58.3ms":28,"62.5ms":7,"66.7ms":7,"75.0ms":1,"116.7ms":1}`
- shared-region observation:
  - `videoSharedRegionPollCount=1105`
  - `videoSharedRegionChangeEventCount=4`
  - `videoSharedRegionDeltaHistogram={"2.9ms":1,"3.1ms":1,"779.4ms":1}`
  - `videoSharedRegionDelta120HzEquivalentCount=2`
  - `videoSharedRegionChangedOffsetHistogram={"0":4,"16":4,"128":1,"136":1,"144":1,"152":1,"480":1,"488":1,"1568":1,"1576":1,"1584":1,"1592":1}`
- recv-fd observation:
  - `videoRemoteQueueRecvFDPollCount=1029`
  - `videoRemoteQueueRecvFDSignalEventCount=2`
  - `videoRemoteQueueRecvFDDeltaHistogram={"354.3ms":1}`
  - `videoRemoteQueueRecvFDAvailableBytesHistogram={"0":1029,"2":2}`
  - `videoRemoteQueueRecvFDAvailableBytesMax=2`

Recent continuous Metal motion sample on display `2` for `3s`:

- public sample presentation histogram:
  - `{"4.2ms":2,"8.3ms":8,"12.5ms":3,"16.7ms":1,"20.8ms":1,"25.0ms":1,"50.0ms":9,"54.2ms":4,"58.3ms":3,"62.5ms":9,"66.7ms":4,"70.8ms":4,"75.0ms":1,"108.3ms":1,"112.5ms":1,"116.7ms":4,"120.8ms":1}`
- shared-region observation:
  - `videoSharedRegionChangeEventCount=0`
  - `videoSharedRegionDeltaHistogram={}`
- recv-fd observation:
  - `videoRemoteQueueRecvFDSignalEventCount=0`
  - `videoRemoteQueueRecvFDDeltaHistogram={}`
  - `videoRemoteQueueRecvFDAvailableBytesHistogram={"0":193}`
  - `videoRemoteQueueRecvFDAvailableBytesMax=0`

Interpretation:

- the public sample path still does not become `120hz-like` under continuous Metal motion
- neither the mapped `SharedRegion` nor the duplicated `RecvFd` exposes a strong `~8.3ms` producer cadence
- the lower observable state is either too far upstream / too passive, or the real per-frame handoff lives in the consumer callback path rather than these read-only queue artifacts
- the next meaningful lower target is therefore the actual queue-drain / consumer callback path, not more passive polling of `SharedRegion` or `RecvFd`

## Recent passive consumer sweep

Recent passive traces on the current main display (`AW2725Q`, display `3`, `UI Looks like 2560 x 1440 @ 240Hz`) now support auto-selecting the default display from the host CLI. The latest traces still show public delivery clustering around `16.7ms` / `20.8ms`, for example:

- `sampleBufferEventCount=111` over `2s`
- `sampleBufferPresentationDeltaHistogram={"8.3ms":1,"12.5ms":2,"16.7ms":83,"20.8ms":22,"25.0ms":2,"66.7ms":1}`

Additional passive hooks that were tested and found inactive on this path:

- `_videoReceiveQueue` wrapper callback
  - `videoQueueWrapperInstalledCount=1`
  - `videoQueueWrapperCallbackEventCount=0`
- `IOSurfaceRemoteRemoteClient`
  - `surfaceTransportHandleMessageEventCount=0`
- `CMCaptureFrameReceiver`
  - `frameReceiverEventCount=0`
  - `frameReceiverKindHistogram={}`
- `BWRemoteQueueSinkNode`
  - `remoteQueueSinkKindHistogram={}`
- `BWImageQueueSinkNode`
  - `remoteQueueSinkKindHistogram={}`
- `BWNodeConnection consumeMessage:fromOutput:`
  - `remoteQueueSinkKindHistogram={}`
- `BWNode _handleMessage:fromInput:`
  - `remoteQueueSinkKindHistogram={}`

Interpretation:

- the wrapper installed on `_videoReceiveQueue` but never observed a callback, which strongly suggests that the currently visible wrapper slot is not the active hot consumer for public display capture
- the generic `BW*` graph hooks that looked promising from runtime class discovery are also not part of the active consumer path in this specific `SCStream` display-capture flow
- the remaining live path is therefore likely either:
  - still inside `RPDaemonProxy` / an unhooked `SCStream` consumer transition, or
  - in additional dynamically loaded classes that were not part of the earlier fixed runtime inventory set

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

1. Move below the passive `SharedRegion` / `RecvFd` observers and trace the real queue-drain / consumer callback path.
2. Correlate public timing traces with WindowServer/compositor activity instead of assuming static-scene coalescing is the dominant cause.
3. If a lower-level consumer still shows the same `45-70ms` gap cluster, treat compositor cadence policy as the primary ceiling.
4. Keep the virtual display UI/classification track separate from the capture-cadence track.
