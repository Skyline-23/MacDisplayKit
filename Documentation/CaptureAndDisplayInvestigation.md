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

After replacing the `_videoReceiveQueue` block hook with an invoke-pointer patch, the previously silent wrapper callback became the first live lower-level consumer signal on this path:

- `videoQueueWrapperInstalledCount=1`
- `videoQueueWrapperCallbackEventCount=109`
- `videoQueueWrapperCallbackCadenceClassification=60hz-like`
- `firstPrivateQueueSource=video-queue-wrapper-callback`
- `privateQueueLeadMilliseconds=3.590375`
- `surfacePointerMatched=true`

Interpretation:

- the local `_videoReceiveQueue` drain callback is live and sees the same `IOSurface` pointer that later reaches the public `stream:didOutputSampleBuffer:ofType:` callback
- the lead from the first live queue callback to the first public sample is only about `3.6ms`, so the public callback layer is not the primary ceiling
- the live local drain callback is itself `60hz-like`, which means the practical cadence ceiling already exists at or before that local consumer boundary

Additional passive hooks that were tested and still appear inactive on this public display-capture path:

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

- the generic `BW*` graph hooks that looked promising from runtime class discovery are also not part of the active consumer path in this specific `SCStream` display-capture flow
- the remaining live path is therefore likely either:
  - in the queue scheduling and setup transition immediately ahead of the `_videoReceiveQueue` local drain callback, or
  - in additional dynamically loaded classes that are still upstream of that callback and not yet hooked

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

## Latest lower-path sweep

Two more lower-path checks were added after the passive consumer sweep.

### Runtime inventory expansion

The runtime inventory no longer relies only on a fixed class list. A dynamic runtime scan now adds loaded class names whose names imply queue / receiver / sink / frame / surface / capture responsibilities.

That surfaced additional candidates that were not previously visible in the fixed inventory, including:

- `FigScreenCaptureController`
- `FigScreenCaptureConfiguration`
- `CMCaptureFrameSenderClient`
- `CMCaptureFrameSenderService`

Useful method highlights from the dynamic scan:

- `FigScreenCaptureController`
  - `startCapture`
  - `resumeCapture`
  - `suspendCapture`
  - `stopCapture`
- `FigScreenCaptureConfiguration`
  - `minFrameInterval`
  - `numOfIdleFrames`
  - `sourceRect`
- `CMCaptureFrameSenderClient`
  - `sendXCPSampleBuffer:`
- `CMCaptureFrameSenderService`
  - `sendFrame:`
  - `_newSampleBufferToSendFromSampleBuffer:`

Interpretation:

- the live runtime contains lower capture/controller classes beyond the original public `SCStream` wrapper surface
- the most promising new control-plane candidates are now `FigScreenCaptureController` and the `CMCaptureFrameSender*` pair

### FigRemoteQueueReceiver runtime interpose status

The passive trace now emits explicit `FigRemoteQueueReceiver` interpose-install notes, not just event counts. On the current public display-capture path they still show up as unresolved:

- `figRemoteQueueReceiverInterposeAttempted=<null>`
- `figRemoteQueueReceiverInterposeInstalled=<null>`
- `figRemoteQueueReceiverHandlerCallbackEventCount=0`
- `figRemoteQueueReceiverDequeueEventCount=0`

Interpretation:

- the exported `FigRemoteQueueReceiver*` path is still not proving to be the live drain for public `SCStream` display capture
- either the runtime interpose never becomes relevant to the active path, or the hot path is using a different internal family entirely

### FigScreenCaptureController lifecycle hook result

`FigScreenCaptureController` lifecycle methods were hooked in the host-only trace layer:

- `startCapture`
- `resumeCapture`
- `suspendCapture`
- `stopCapture`

Recent passive traces did not report any of these lifecycle events.

Interpretation:

- even though the class is loaded, the current public `SCStream` display-capture flow does not appear to call directly through `FigScreenCaptureController` in a way that the host-only trace can currently observe
- this keeps the most plausible hot path inside `SCStream`'s own local queue-drain / consumer logic rather than a directly visible `FigScreenCaptureController` lifecycle

### Working conclusion

The current best lower-level model is now:

- `SCStreamManager startRemoteQueue:streamID:` and `SCRemoteQueueXPCObject setRemoteQueue:/setQueueType:` are still the cleanest control-plane anchors
- the active drain is inside `SCStream` local consumer logic rather than in exported `FigRemoteQueueReceiver*`
- the first live `_videoReceiveQueue` callback arrives about `15.75ms` after `stream-post-start-remote-video-state`
- the raw immediate predecessor of that first callback is still microphone queue startup noise:
  - `firstVideoQueueCallbackPrecedingEventKind=stream-start-remote-microphone-receive-queue`
  - `firstVideoQueueCallbackPrecedingEventLeadMilliseconds=15.409625`
- the last video-specific setup milestone before the first callback remains:
  - `firstVideoQueueCallbackLastSetupEventKind=stream-post-start-remote-video-state`
  - `firstVideoQueueCallbackLastSetupEventLeadMilliseconds=15.75475`
- the raw wrapper under `_videoReceiveQueue` is tiny and stable:
  - `videoReceiveQueueWrapperMallocSize=48`
  - `videoReceiveQueueWrapperCandidateBlockOffsets=[40]`
  - `videoQueueWrapperInstalledOffset=40`
- the block currently patched at wrapper offset `40` originally points at:
  - `videoQueueWrapperOriginalInvokeSymbol=__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`
  - `videoQueueWrapperOriginalInvokeImagePath=/System/Library/PrivateFrameworks/CMCapture.framework/Versions/A/CMCapture`
- wrapper capture slot `32` is not an opaque struct after all; it is another `48`-byte malloc block:
  - `videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize=48`
  - `videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol=_NSConcreteMallocBlock`
  - `videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=/usr/lib/system/libsystem_blocks.dylib`
- that nested block resolves to ScreenCaptureKit's own local video receive setup:
  - `videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol=__59-[SCStream(SCContentSharing) startRemoteVideoReceiveQueue:]_block_invoke`
  - `videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit`
- `collectStreamData` does not appear to be the missing hot gate immediately before the first local drain callback:
  - `lastCollectStreamDataEnterLeadMilliseconds=<null>`
  - `lastCollectStreamDataExitLeadMilliseconds=<null>`
- a first attempt to interpose that nested block at wrapper-install time did not fire:
  - `videoQueueNestedBlockCallbackEventCount=0`
  - `videoQueueNestedBlockOriginalInvokeSymbol=<null>`
  - `firstVideoQueueNestedBlockCallbackTimestampNanos=<null>`
- this suggests the nested `startRemoteVideoReceiveQueue:` block is discoverable in passive snapshots, but not yet stable/live at the exact moment the wrapper hook is installed
- this shifts the next remaining ceiling from generic `collectStreamData` timing to the `FigRemoteOperationReceiverCreateMessageReceiver` path that owns the original video wrapper callback
- the next most promising technical target is now the local video receive path around:
  - `__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`
  - the code path that allocates or late-populates the wrapper capture slot at offset `32`
  - `__59-[SCStream(SCContentSharing) startRemoteVideoReceiveQueue:]_block_invoke`

Follow-up passive trace after fixing the nested-block signature gate and allowing
`FigRemoteOperation` blocks to interpose:

- `videoQueueNestedBlockCallbackEventCount=44`
- `videoQueueNestedBlockCallbackCadenceClassification=coalesced-or-mixed`
- `videoQueueNestedBlockOriginalInvokeSymbol=__59-[SCStream(SCContentSharing) startRemoteVideoReceiveQueue:]_block_invoke`
- `firstSuccessfulVideoQueueNestedBlockRescanReason=wrapper-install`
- `firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds=31.340458`
- `firstVideoQueueNestedBlockCallbackTimestampNanos=16130747870416`
- `firstVideoQueueNestedBlockLeadMilliseconds=0.597209`
- `firstPublicSamplePrecedingEventKind=video-queue-nested-block-callback`
- `firstPublicSamplePrecedingEventLeadMilliseconds=0.597209`

Interpretation:

- the nested `startRemoteVideoReceiveQueue:` block is not a dead snapshot artifact; it is
  now confirmed live on the steady-state path
- the first successful nested-block install happens as early as `wrapper-install`, so the
  earlier rescan points are not the main missing piece
- the nested ScreenCaptureKit local callback fires about `0.6 ms` before the first public
  sample, which makes it the closest confirmed lower-level predecessor we have so far
- its cadence classification still matches the wrapper callback (`coalesced-or-mixed`), so
  the ceiling is still below or at the transition into this local ScreenCaptureKit receive block

Most recent `1s` passive trace on the same path tightened that conclusion further:

- `videoQueueWrapperCallbackCadenceClassification=60hz-like`
- `videoQueueNestedBlockCallbackCadenceClassification=60hz-like`
- `videoQueueWrapperToNestedLeadPairCount=49`
- `videoQueueWrapperToNestedLeadHistogram={"0.1ms":40,"0.2ms":8,"3.7ms":1}`
- `videoQueueWrapperToNestedLeadMinMilliseconds=0.0515`
- `videoQueueWrapperToNestedLeadMaxMilliseconds=3.689875`
- `firstVideoQueueNestedBlockLeadMilliseconds=0.767833`
- `firstPublicSamplePrecedingEventKind=video-queue-nested-block-callback`
- `firstPublicSamplePrecedingEventLeadMilliseconds=0.767833`

Interpretation:

- the wrapper callback and the nested ScreenCaptureKit local receive block are effectively in the
  same scheduling slice for most frames
- almost every wrapper-to-nested handoff is sub-millisecond, so there is no meaningful headroom in
  that boundary
- when this run classifies both wrapper and nested callbacks as `60hz-like`, the remaining ceiling
  is very likely at or before `__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`

Follow-up passive trace after adding wrapper invoke entry/exit tracing around
`__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`:

- `videoQueueWrapperInvokeEntryCadenceClassification=60hz-like`
- `videoQueueWrapperInvokeExitCadenceClassification=60hz-like`
- `videoQueueInvokeEntryToExitLeadPairCount=109`
- `videoQueueInvokeEntryToExitLeadHistogram={"0.0ms":3,"0.1ms":64,"0.2ms":35,"0.3ms":3,"0.7ms":2,"0.8ms":1,"3.9ms":1}`
- `videoQueueInvokeEntryToExitLeadMinMilliseconds=0.024334`
- `videoQueueInvokeEntryToExitLeadMaxMilliseconds=3.923333`
- `videoQueueNestedAttributedCallbackCount=109`
- `videoQueueNestedUnattributedCallbackCount=0`
- `videoQueueNestedInsideWrapperSequenceCount=109`
- `videoQueueInvokeEntryToNestedLeadHistogram={"0.0ms":27,"0.1ms":79,"0.2ms":2,"3.3ms":1}`
- `videoQueueNestedToInvokeExitLeadHistogram={"0.0ms":48,"0.1ms":57,"0.6ms":2,"0.7ms":2}`
- `firstVideoQueueNestedBlockPrecedingEventKind=video-queue-wrapper-invoke-entry`
- `firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds=3.288333`
- `firstVideoQueueNestedBlockInsideWrapperOriginalInvoke=1`

Interpretation:

- the entry and exit of `__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke` are still
  `60hz-like`, matching the wrapper callback and the nested ScreenCaptureKit local receive block
- every observed nested callback in this run stayed inside an active wrapper-original-invoke
  interval (`109/109` attributed, `109/109` inside), so the nested handoff is synchronously
  contained within the CMCapture wrapper path rather than being posted later on a different thread
- almost every entry-to-exit, entry-to-nested, and nested-to-exit handoff is sub-millisecond, so
  there is no meaningful headroom inside that wrapper body itself
- this pushes the remaining cadence ceiling one step farther upstream and makes it very likely that
  the dominant `60hz-like` behavior is already fixed before entry into
  `__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`

Follow-up passive trace after adding first-entry/exit backtrace capture around the same wrapper:

- `videoQueueWrapperInvokeEntryCadenceClassification=60hz-like`
- `videoQueueWrapperInvokeExitCadenceClassification=60hz-like`
- `firstVideoQueueWrapperInvokeEntryFirstInterestingFrame={"symbolName":"__rqReceiverSetSource_block_invoke","imagePath":"/System/Library/PrivateFrameworks/CMCapture.framework/Versions/A/CMCapture","symbolOffset":260}`
- `firstVideoQueueWrapperInvokeExitFirstInterestingFrame={"symbolName":"__rqReceiverSetSource_block_invoke","imagePath":"/System/Library/PrivateFrameworks/CMCapture.framework/Versions/A/CMCapture","symbolOffset":260}`
- `videoQueueInvokeEntryToExitLeadHistogram={"0.1ms":25,"0.2ms":16,"0.3ms":9,"0.7ms":2,"0.9ms":1,"4.4ms":1}`
- `firstVideoQueueNestedBlockInsideWrapperOriginalInvoke=1`

Interpretation:

- the first non-shim caller visible above `__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke`
  is now identified as `CMCapture::__rqReceiverSetSource_block_invoke`
- entry and exit of the lower wrapper still collapse to the same `60hz-like` cadence, so the next
  meaningful interpose target has moved one frame higher into the `rqReceiverSetSource` path
- the immediate next technical target is therefore the CMCapture receive-source boundary around
  `__rqReceiverSetSource_block_invoke`, not the later ScreenCaptureKit local receive block

Follow-up passive trace after attempting a direct interpose on
`CMCapture::__rqReceiverSetSource_block_invoke` and then enriching the wrapper-side container
summary:

- `rqReceiverSetSourceInterposeInstalled=1`
- `rqReceiverSetSourceInvokeEntryEventCount=0`
- `videoReceiveQueueWrapperSlot32PointeeObjectClassName=__NSCFType`
- `videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName=OS_dispatch_source`
- `videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription=<OS_dispatch_source: 0xc5f2d5280>`
- `videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol=_ZL34MDKInterposedVideoQueueBlockInvokePviP24MDKFigRemoteQueueMessageS_`
- `videoQueueWrapperInvokeEntryCadenceClassification=60hz-like`

Interpretation:

- the dyld interpose attempt on `__rqReceiverSetSource_block_invoke` resolves and installs, but it
  never receives live callbacks in-process; this is consistent with an internal block invoke path
  that is not reached through a relocatable external call site
- the wrapper's auxiliary slot-32 container is now confirmed to hold an `OS_dispatch_source`
  alongside the live wrapper block itself
- that makes the dispatch-source wakeup boundary the next meaningful upstream cadence gate, not the
  already-confirmed ScreenCaptureKit local receive block or the wrapper invoke body
- in practical terms, the remaining ceiling is now best modeled as `dispatch source scheduling ->
  CMCapture wrapper block -> SCStream nested block -> public sample`, with the first stage still
  unproven and the latter three already observed as `60hz-like` or sub-millisecond handoffs

Follow-up passive trace after decoding the live `OS_dispatch_source` object via libdispatch APIs:

- `videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName=OS_dispatch_source`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle=3`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType=fifo`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode=4528`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath=nil`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer=nil`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName=OS_dispatch_queue_serial`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription=<OS_dispatch_queue_serial: com.skyline23.MacDisplayKit.sck-proxy-trace>`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol=_dispatch_source_type_read`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask=0`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData=2`
- `videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled=0`
- `rqReceiverSetSourceInvokeEntryEventCount=0`
- raw wrapper snapshots on the same run also resolve the sibling queue handles to fifo-backed
  dispatch sources:
  - audio wrapper `handle=5`, `fileType=fifo`, `data=0`
  - microphone wrapper `handle=7`, `fileType=fifo`, `data=0`

Interpretation:

- the upstream wakeup object for the video receive path is not a mach-receive source; the live
  dispatch source currently reports `handle=3` and resolves to a `fifo`, so the wakeup path is
  fd-backed pipe scheduling rather than a mach-message receive source
- the queue family is consistent across media types; ScreenCaptureKit/CMCapture appears to allocate
  separate fifo-backed dispatch sources per remote receive queue rather than multiplexing them
  through one mach source
- the video-side source is explicitly a libdispatch `read` source and its target queue is the same
  serial sample-handler queue used by the host trace, so the downstream scheduling boundary is now
  strongly localized to `fifo readability -> dispatch source fire -> wrapper block`
- the dispatch source has no custom context pointer, so the next likely recoverable hook point is
  the libdispatch read-source handler registration or the producer that writes into the fifo
- `mask=0` and `data=2` mean the wakeup side is still opaque, but the source is active rather than
  cancelled and is almost certainly sitting in front of the already-confirmed wrapper block
- together with the failed `rqReceiverSetSource` interpose, the next practical reverse-engineering
  target is now the fd-backed dispatch-source scheduling boundary and its read/drain path rather
  than the later CMCapture or ScreenCaptureKit local blocks

Follow-up passive trace after interposing public libdispatch read-source APIs:

- note: `Installed dispatch read-source interpose on 2 image(s).`
- observed `dispatch-read-source-create` events: `0`
- observed `dispatch-read-source-set-event-handler` events: `0`
- observed `dispatch-read-source-set-event-handler-f` events: `0`

Interpretation:

- the ScreenCaptureKit/CMCapture path visible in this host process does not currently register the
  video fifo source through imported `dispatch_source_create` / `dispatch_source_set_event_handler*`
  call sites in the interposed images
- because the interpose is active on both `ScreenCaptureKit` and `CMCapture`, the remaining likely
  explanations are:
  - the source is created through a lower libdispatch-internal path that bypasses those public
    import stubs
  - the source/handler is created before the currently observable handshake window and only reused
    during capture
  - the higher-signal next hop is the fifo producer/write side rather than public read-source
    registration

Follow-up passive trace after interposing fifo drain syscalls:

- note: `Installed fifo read interpose on 3 image(s) using 2 symbol(s).`
- observed `fifo-read` events: `0`
- observed `fifo-read-nocancel` events: `0`

Interpretation:

- the live consumer drain immediately upstream of the wrapper callback is not flowing through
  imported `read` / `read_nocancel` call sites in `ScreenCaptureKit`, `CMCapture`, or
  `libdispatch`
- this cuts off the straightforward syscall route and makes `fifo readability -> dispatch source
  fire -> wrapper block` even narrower: the remaining viable boundary is the libdispatch-internal
  source invoke/fire path or a producer-side wakeup path that never exposes a userspace `read`
  import in the traced images
- because the already-confirmed wrapper and nested ScreenCaptureKit callbacks remain `60hz-like`,
  the missing `read` events are evidence that the scheduling ceiling is not inside those local
  callbacks and not inside a public fifo drain wrapper either
