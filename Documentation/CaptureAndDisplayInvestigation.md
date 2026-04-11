# Capture And Display Investigation

This document accumulates reverse-engineering findings gathered while extracting the macOS display and capture runtime into `MacDisplayKit`.

It focuses on two threads:

- virtual display behavior and macOS display-class limits
- ScreenCaptureKit timing and capture cadence behavior

## Current scope

- repo: `MacDisplayKit`
- host app: `MacDisplayKitHost`
- goal: understand what limits high-frequency HDR display capture on macOS and separate policy from mechanism

## Current encoded-capture autoresearch state

This section is the compact handoff state for the active downstream optimization loop. The rest of
this document remains the broader investigation record.

### Downstream target and hard constraints

- downstream app: `Lumen`
- target mode:
  - `3512x2290`
  - `120 fps`
  - codecs: `hevc`, `prores-proxy`
- hard constraints:
  - no implicit downscale
  - no SDR fallback during active interaction
  - partial HDR overlay must remain enabled
  - no new dependencies for optimization work

### Current best result

- downstream experiment: `367`
- MDK commit: `097cfff`
- score: `92.92`

Best measured output:

- `HEVC`
  - `RUNTIME_SCORE_HEVC=67.92`
  - `frames=38`
  - `startup_ms=285.576`
  - `avg_callback_latency_ms=20.770`
  - `max_callback_latency_ms=68.698`
- `ProRes Proxy`
  - `RUNTIME_SCORE_PRORES_PROXY=80.98`
  - `frames=35`
  - `startup_ms=127.171`

### Current keep stack

- active downloads-checkout keep:
  1. `CaptureEncodedSession.swift`
     - raw SkyLight callback path keeps the callback-only HEVC high-refresh pending depth at `2`
  2. `CaptureVideoToolboxProcessing.swift`
     - high-refresh PQ HDR HEVC uses `ExpectedFrameRate` and `ExpectedDuration` hints at `240 Hz`
     - high-refresh PQ HDR HEVC uses `VBVBufferDuration=1/30s` with default initial delay
     - immediate recovery replay is suppressed while `NumberOfPendingFrames > 0`
  3. `CaptureVideoCodec.swift`
     - HEVC low-latency bitrate ceiling is `192 Mbps`

### What is now closed

- source-to-processor queue structure
  - `371 / a67d73e / 92.50`
    - inline raw HEVC submit from the source callback regressed HEVC progression
  - `372 / 5c341cb / 92.50`
    - removing the raw SkyLight delivery queue regressed callback isolation and progression
  - `376 / 7c60943 / 92.50`
    - moving direct VT bookkeeping onto `encodeQueue` did not help
  - `379 / 6cae5d6 / 92.29`
    - replacing the pending-frame gate with an actor latest-wins ingress scheduler regressed both codecs
- encoder pacing and startup
  - `368 / cfb9ed6 / 92.71`
    - shrinking `VBVBufferDuration` from `1/30` to `1/60` regressed ProRes progression
  - `373 / 99371e9 / 92.71`
    - driving VT PTS from source display time globally hurt ProRes
  - `374 / f63a0f7 / 92.71`
    - HEVC-only source display time PTS was still below the keep
  - `375 / cbcee28 / 92.50`
    - aligning VT duration to source cadence dropped HEVC back to `36` frames
  - `377 / 73c9204 / 92.71`
    - VT prewarm did not improve startup or progression
- partial-update metadata at encode-only layer
  - `380 / 592a32a / 92.29`
    - propagating raw SkyLight reduced dirty rects into `VTCompressionSessionEncodeFrame` `DirtyRects` produced no measurable gain
  - `388 / b1ad1a7 / 92.71`
    - carrying reduced dirty rect metadata into the processor and only reusing the last completed staging slot for partial BGRA-to-YUV conversion kept correctness intact, but it did not lift progression and pushed `HEVC` startup out to `427.611 ms`
    - conclusion: partial-update reuse that begins after the full source surface is already in hand is still too late in the pipeline to move the ceiling
- raw-source / submit-handoff structure
  - `381 / dcfa594 / 92.71`
    - retuning the high-refresh SkyLight bootstrap around `q1/q2` did not improve the official metric; raw source changes alone still left the downstream ceiling in HEVC progression
  - `382 / a9a1a39 / 92.50`
    - moving VT submit off the callback thread with a plain async handoff improved raw diagnostics but regressed the official metric, which means stale pressure replaced callback stall
  - `383 / e36672a / 92.71`
    - a processor-local HEVC latest-wins submit mailbox recovered some of that regression, but still failed to beat the keep
  - `384 / 15309d6 / 92.71`
    - pairing `q8` source depth with the processor-local mailbox just added pressure; HEVC stayed flat and `ProRes Proxy` regressed
  - `385 / c2a6b88 / 92.50`
    - moving HEVC handoff to a latest-fresh source gate over-dropped under load and regressed HEVC to `36` frames
  - `389 / e590e7b / 92.71`
    - disabling synthetic SkyLight timer replay entirely regressed both codecs, which means the replay path is still carrying real progression value under the current source/backend ceiling
  - `390 / 2899e8a / 92.29`
    - gating synthetic timer replay on source pending-idle was too aggressive; HEVC fell to `35` frames and startup slipped to `338.540 ms`
    - conclusion: source-side pending count is not a faithful proxy for stale synthetic replay pressure
  - `391 / 909e7da / 92.71`
    - suppressing only `timerReplay` frames when HEVC HDR `VTCompressionSession` `NumberOfPendingFrames > 1` recovered HEVC to `37` frames, but startup regressed to `360.491 ms` and still stayed below the keep
    - conclusion: VT-pending-aware replay suppression is directionally safer than source-side gating, but it still loses the current progression/startup balance
  - `392 / 610705e / 92.50`
    - moving only HEVC high-refresh HDR `timerReplay` frames onto an encode-queue latest slot, while keeping `fresh` frames synchronous, still regressed the official metric
    - conclusion: even synthetic-only mailboxing is too lossy under the current path; replay/handoff experiments are now well explored and should give way to source-visible partial capture or a new backend entry point
  - `406 / 4042192 / 95.42`
    - skipping reduced dirty-rect / update-drop metadata decode on the hot high-refresh raw callback path did not improve the official metric
    - `HEVC` regressed to `50` frames with `320.308 ms` startup and `102.072 ms` average callback latency
    - conclusion: the current bottleneck is not the diagnostic metadata decode itself
  - `407 / e8daed1 / 95.21`
    - splitting raw SkyLight `timerReplay` onto a dedicated replay queue while leaving fresh callback delivery on the old serial lane regressed the official metric
    - `HEVC` fell to `49` frames with `325.653 ms` startup and `102.190 ms` average callback latency
    - conclusion: fresh/replay lane separation by itself breaks a progression-supporting ordering relationship in the current best path
  - `408 / f65e1d4 / 95.42`
    - adding explicit `kCGDisplayStreamColorSpace=sRGB` to the production raw `SLDisplayStream` property dictionary did not improve the official path
    - `HEVC` only rose to `50` frames while startup regressed to `379.589 ms`
    - conclusion: a single extra source color-space property is not enough to recover the current cadence ceiling
  - `409 / 1dc4c8f / 95.42`
    - adding explicit full-display `sourceRect` and target-sized `destinationRect` to the production raw `SLDisplayStream` contract only shifted the tradeoff
    - `HEVC` landed at `50` frames with `309.862 ms` startup and `99.598 ms` average callback latency, but `ProRes Proxy` fell to `25` frames
    - conclusion: explicit rect contract can move source behavior, but it still does not solve the shared two-codec ceiling by itself
  - `410 / 66fbd3c / 95.42`
    - bypassing staged replay resubmission copies and reusing the last fresh staged pixel buffer for replay-origin frames did not improve the official path
    - `HEVC` stayed at `50` frames and startup regressed to `350.261 ms`
    - conclusion: replay-side duplicate Metal copy is not the dominant source of the current progression ceiling
  - `411 / f0da95e / 51.42`
    - making the `processor.process -> encodeQueue` handoff asynchronous destroyed stability instead of improving freshness
    - `HEVC` reported `22` drop events and the official score cratered, even though startup moved down to `336.406 ms`
    - conclusion: the current pending-frame and completion contract still relies on a synchronous submit boundary; removing it without redesigning the backpressure model is invalid
  - `412 / aad190b / 95.21`
    - raising the production raw `SLDisplayStream` callback queue to `userInteractive` QoS regressed `HEVC` to `49` frames
    - conclusion: callback-thread priority is not the missing source/backend lever
  - `413 / a3e5e72 / 53.42`
    - replacing the source-runtime `deliveryQueue` with an actor replay coordinator and replay-only timer queue removed the single serialized source lane entirely
    - `HEVC` immediately destabilized with `21` drop events and `RUNTIME_SCORE_HEVC=28.42`
    - conclusion: freeing fresh callbacks without keeping a bounded source-side drain just floods the existing VT path; the next source-runtime redesign has to stay bounded and latest-wins rather than fully concurrent
  - `414 / 5863edc / 95.42`
    - reworking the same source-runtime ingress into an actor-backed bounded latest-wins drain preserved stability, but it still left `HEVC` pinned at `50` frames with `330.665 ms` startup and `100.152 ms` average callback latency
    - conclusion: source-runtime-only latest-wins rebinding is not enough either; the remaining ceiling is upstream/downstream of that drain, not in the old serial lane by itself
  - `415 / 257bcaf / 95.21`
    - moving the bounded latest-wins drain up to the session ingress so the source callback returned immediately still regressed the official metric
    - `HEVC` fell to `49` frames and `ProRes Proxy` picked up `2` drop events
    - conclusion: ingress-only decoupling is now closed too; returning from the source callback earlier does not by itself recover the lost progression
  - `416 / a189aaa + 237d24af / 95.42`
    - carried the producer dirty-region through `MDKEncodedFrame`, the `LumenCore` ingress ABI, the Swift/ObjC bridge, and finally into `video.cpp` so `sdr_base_hdr_overlay` could build its overlay region from source dirty rects instead of only from the display content box
    - official metric stayed below keep: `HEVC=50` frames with `425.598 ms` startup and `102.302 ms` average callback latency, `ProRes Proxy=30` frames with `146.281 ms` startup
    - conclusion: preserving selective-HDR truth through the bridge is valid correctness work, but it is not the current 120 Hz progression bottleneck; the encode path is still paying essentially the same cadence cost
  - `417 / 23b991e / 25.00`
    - replaced the SkyLight encoded source's serial `deliveryQueue` with an actor replay state plus `AsyncStream(bufferingNewest: 1)` latest-wins ingress so the raw callback could return immediately without queueing every frame
    - same-host host diagnostics improved materially: `sourceApproxFrameRate` rose from about `49.83` to about `77.92` while raw SkyLight on the same host still measured about `123.74 fps`
    - the official metric still cratered because the `HEVC` runtime probe failed outright; `ProRes Proxy` survived at `79.58`, but the combined score collapsed to `25.00`
    - conclusion: source callback serialization is a real bottleneck, but naive latest-wins ingress breaks the current HEVC recovery/backpressure invariants; the next redesign has to preserve official stability while reclaiming source cadence
  - `418 / 34ffbeb3 / 95.42`
    - removed the immediate `arm_wait_for_next_idr(...)` escalation for `capture processing queue is saturated` and `core-forwarder-overflow` drop events in `video.cpp`, while preserving the repeated-saturation restart path
    - the official metric stayed stable but did not move the ceiling: `HEVC=50` frames with `320.597 ms` startup and `100.226 ms` average callback latency, `ProRes Proxy=26` frames with `148.529 ms` startup
    - conclusion: drop-triggered decoder resync is downstream noise, not the primary progression ceiling; the dominant loss still happens before or inside progression itself
  - `419 / f3f6909 / 95.42`
    - replaced the SkyLight encoded source's serial `deliveryQueue` with an actor-backed bounded latest-wins ingress that tracked in-flight credits and returned source-release callbacks only when downstream work completed
    - the official metric remained stable but still flatlined: `HEVC=50` frames with `366.011 ms` startup and `101.338 ms` average callback latency, `ProRes Proxy=27` frames with `144.280 ms` startup
    - conclusion: even a bounded actor ingress that preserves stability does not move the official ceiling, so source-runtime ingress serialization is no longer the primary suspect
  - `420 / b4ae57e / 25.00`
    - inserted an actor-backed bounded latest-wins submit coordinator between `processor.process(...)` and `encodeQueue.sync { VTCompressionSessionEncodeFrame(...) }` so high-refresh frames could replace stale work before the VideoToolbox submit boundary
    - the official metric cratered immediately: `HEVC=48` frames with `321.936 ms` startup and `103.706 ms` average callback latency, while `ProRes Proxy=30` frames with `158.821 ms` startup
    - conclusion: the synchronous VideoToolbox submit/completion boundary is part of the current recovery and drain contract, so latest-wins/drop semantics at that boundary are invalid; the next redesign has to preserve submit ordering and remove cost before submit instead
  - `421 / 87e0992 / 95.42`
    - cached HDR `CVBufferSetAttachment(...)` application per direct source surface and per reusable staging slot so the direct/staged submission buffers only received HDR attachments once instead of on every submit
    - the official metric still flatlined: `HEVC=50` frames with `298.033 ms` startup and `100.770 ms` average callback latency, while `ProRes Proxy` regressed to `24` frames with `148.615 ms` startup
    - conclusion: repeated HDR attachment writes are not the dominant progression cost; they can trim startup slightly, but they do not move the 120 Hz encode ceiling and they are not worth keeping if ProRes regresses
  - `422 / 7851f15 / 25.00`
    - replaced the inline `deliveryQueue -> processor.process(...)` call with an actor-backed ordered drain so source callbacks only enqueued frames and a separate serial actor lane performed `processor.process(...)` in order
    - official stability collapsed immediately: `HEVC=49` frames with `354.161 ms` startup, `103.671 ms` average callback latency, and `54` drop events, while `ProRes Proxy` rose to `36` frames
    - the same binary's local encoded-session diagnostic was still crucial: `sourceApproxFrameRate≈108.69` and `sourceCadenceClassification=120hz-like` returned while `observedOutputFrameRate` stayed near `43`, which proves the current production source choke is the inline submit coupling, not the raw backend
    - conclusion: decoupling the source callback from `processor.process(...)` is directionally right, but it is invalid unless the new drain is paired with an explicit encoder-side flow-control gate (for example `VTCompressionSession` pending-state admission) so HEVC does not flood as soon as source cadence recovers
  - `423 / 9fed388 / 95.21`
    - changed high-refresh HEVC so the source permit was released on the actual encoder output callback instead of immediately after `VTCompressionSessionEncodeFrame(...)` returned
    - official stability recovered, but the gate was too conservative: `HEVC=49` frames with `316.606 ms` startup and `101.247 ms` average callback latency, while `ProRes Proxy` improved to `31` frames with `136.372 ms` startup
    - the same binary's local encoded-session diagnostic fell back to `sourceApproxFrameRate≈41.57`, showing that output-callback gating restores the old source choke instead of preserving the `422` source-cadence recovery
    - conclusion: the new flow-control gate needs to sit between `submit returned` and `output callback drained`; `VTCompressionSession` pending-state admission is the next concrete direction
  - `387 / 1834570f / 72.71`
    - reworking `sdr_base_hdr_overlay` so `HEVC` used an SDR `420v8` base stream and overlay state came from the external metadata contract did not survive the official metric:
      - synthetic stayed `100`
      - runtime probe still observed `0` overlay-HDR frames on both codecs
      - `HEVC` only reached `37` frames at `348.338 ms` startup and `ProRes Proxy` dropped to `33` frames
    - conclusion: changing the bridge and ingress contract is not enough unless the producer/probe can source a real overlay-active signal independently of encoded sample-buffer HDR signalling

### Root bottleneck reading

- the limiting path is no longer best explained by queue ownership or simple VT property tuning
- the current evidence points higher up the stack, at raw source/backend cadence
- raw source numbers are the critical anchor:
  - latest raw SkyLight benchmark, `3512x2290`, `q2`, `x420`, `none`: about `84.41 fps`
    - the same run reported `avgReducedDirtyCoverageRatio=0.256`, `avgReducedDirtyRectCount=2.361`, `avgUpdateDropCount=0.030`, and `WindowServer pcpu≈9.6`
    - even in this cleaner host state, long-gap ratio over `16 ms` stayed about `0.28`, so the source still misses a stable `120 Hz` cadence
  - latest current-host recheck on the local `MacDisplayKitHost` binary, `3512x2290`, `x420`, `none`, `minimumFrameTime=0`:
    - `q1`: about `63.96 fps`
    - `q2`: about `75.76 fps`
    - `q3`: about `61.94 fps`
    - this keeps `q2` as the least-bad queue-depth on the current host state and closes the “maybe q1/q3 is now better” loop
  - latest current-host pixel-format recheck on the same local binary, `3512x2290`, `q2`, `none`, `minimumFrameTime=0`:
    - `x420`: about `74.91 fps`
    - `bgra`: about `72.93 fps`
    - `x422`: about `69.76 fps`
    - this closes the “maybe switch the raw source away from x420 and recover cadence in GPU conversion” loop for the current host state; `x420` remains the least-bad raw source format
  - latest current-host target-sized queue-depth recheck on the same local binary, `3512x2290`, `x420`, `none`, `minimumFrameTime=0`:
    - `q1`: about `63.43 fps`
    - `q2`: about `124.13 fps`
    - `q3`: about `66.80 fps`
    - this is the most important current anchor: on this host the raw `SLDisplayStream` backend can clear the target cadence at the actual target size, but only with the narrow `q2` contract
    - practical consequence: the deepest open limit is no longer "raw SkyLight cannot hit 120 at target size"; it is the production source-runtime / processor / VT chain above raw delivery
  - earlier raw SkyLight target probes on more loaded host states ranged about `39-51 fps`
  - current raw SkyLight benchmark, `3512x2290`, `q2`, `420v`, `none`: about `45.45 fps`
  - current raw SkyLight benchmark, `3512x2290`, `q8`, `x420`, `none`: about `35.98 fps`
  - current raw SkyLight benchmark, `3512x2290`, `q2`, `bgra`, `none`: about `35.94 fps`
  - current raw SkyLight processing-benchmark attachment probe:
    - `3512x2290`, `x420`, `processing-mode=none`: about `48.26 fps`
    - first propagated attachment keys only include `CGColorSpace` and `HorizontalDisparityAdjustment`
    - `ColorPrimaries`, `TransferFunction`, `YCbCrMatrix`, `MasteringDisplayColorVolume`, and `ContentLightLevelInfo` are all `nil`
  - current raw SkyLight target dirty-region probe:
    - `3512x2290`, `x420`, plain raw benchmark now reports `avgReducedDirtyCoverageRatio` around `0.54`, `avgReducedDirtyRectCount` around `3.4`, and `avgUpdateDropCount=0`
    - on the current host load that same probe only delivers about `39-40 fps`; earlier cleaner-host runs reached about `51.4 fps`
    - conclusion: `CGDisplayStreamUpdateRef` is carrying non-trivial partial-update information, but the source still pays a full-surface cadence cost before any downstream dirty-rect logic can help
  - updated reading from the latest `84.4 fps` anchor:
    - source-only SkyLight can materially outrun the official encoded-session metric, so there is still substantial loss in the handoff / processor / encode chain
    - but even the best source-only target-sized run remains well below `120`, so raw backend cadence and source-visible partial capture are still first-class structural problems
  - full-backing probe shows the same structural limit, not a scaler artifact:
    - default backing (`3840x2160`) with `x420` or `BGRA` still carries no HDR attachment keys beyond `CGColorSpace`
    - `420v` does carry attachment keys, but they are plain SDR `ITU_R_709_2`
  - current production-facing encoded session diagnostic, `HEVC`, `HDR10`, callback mode:
    - `q1`: about `43.5 fps` output, source cadence about `38.8 fps`
    - `q2`: about `43.5 fps` output, source cadence about `34.1 fps`
  - latest current-host encoded-session diagnostic on the local host binary, default production path, `callback-only`, `HEVC`, `HDR10`:
    - `observedOutputFrameRate=38.5`
    - `sourceFrameCount=77`
    - `sourceApproxFrameRate=32.40`
    - runtime notes show:
      - `skyLightTuningCandidate=min-frame-240hz-q2`
      - `videoToolboxDirectSubmissionFrameCount=77`
      - `videoToolboxStagedSubmissionFrameCount=0`
      - `sourceAverageDisplayDeltaMilliseconds=30.865`
    - practical consequence: the biggest remaining collapse on this host is between raw callback delivery and production frame emission, before any staged Metal copy even appears
  - current private direct IOSurface benchmark with HDR request at full display size (`5120x2880`): about `34.54 fps`
  - current private target-sized IOSurface benchmark, `3512x2290`:
    - direct `CGSHWCaptureDisplayIntoIOSurfaceWithOptions`: about `14.7 fps` in SDR and about `14.6 fps` in HDR
    - proxy `SLSHWCaptureDisplayIntoIOSurfaceProxying`: about `14.9` iterations per second but still `0` populated frames
    - conclusion: current private IOSurface paths are materially worse than raw SkyLight at the actual target size, so backend-selection experiments should not pivot to private capture unless a new private entry point changes this baseline
- the raw `vt-encode` benchmark path at `3512x2290/x420/q2` currently collapses to about `1 fps`, so that benchmark is no longer representative of the production encoded-session path
- on the current host state, deeper raw queueing is actively harmful for the source ceiling; `q8` is materially worse than `q2`
- that older reading is now narrowed further by the latest target-sized raw recheck:
  - source-only raw `SLDisplayStream` at `3512x2290/x420/q2` can exceed `120 fps`
  - the production encoded session on the same host still sees only about `32 fps` source cadence before the encoder summary settles
  - practical consequence: the next structural work should focus on the source-runtime handoff contract itself:
    - keep source-side work bounded
    - preserve latest-wins semantics under saturation
    - avoid fully concurrent callback flood into VT
    - avoid reintroducing a single serialized queue that drags fresh callback cadence down to encode pace
- pure encode-side dirty-rect hints are not enough when the production source-runtime still collapses cadence before the VT path gets a chance to benefit
- raw dirty-region statistics sharpen that read:
  - the compositor is not reporting "whole frame changed" every time; typical reduced dirty coverage is materially below `1.0`
  - despite that, the raw source still tops out far below target cadence, which means the expensive part is earlier than VT `DirtyRects` and earlier than processor-local partial staging
  - practical consequence: any future partial-update optimization must either change what the backend captures or avoid forcing whole-surface source work in the first place
- processor-stage dirty-rect reuse is also too late:
  - `388` reused the previous completed staging slot and limited BGRA-to-YUV work to the dirty union, but startup regressed sharply while `HEVC` progression stayed effectively flat
  - that narrows the remaining leverage to source-visible partial capture, overlay-truth derivation, or a backend that never forces full-frame staging in the first place
- `420v8` is directionally better than `BGRA` for an SDR base stream on this host, but it still sits far below the target ceiling, so simply swapping the raw surface format does not solve the underlying cadence limit
- current private capture numbers close the most obvious backend-switch escape hatch:
  - target-sized private direct capture is not merely "not better"; it is dramatically worse than raw SkyLight on this host
  - target-sized proxy capture still does not deliver populated frames, so it remains non-viable for production

### Next structural directions

- stop treating `CGDisplayStreamUpdateRef` as an encode-only hint source
  - `DirtyRects` at VT did nothing on its own
  - the remaining open path is to use partial update metadata earlier, before full-frame processing decisions are locked in
  - `388` closed the processor-local variant of that idea; any further dirty-rect experiment has to start before full-frame source wrapping / staging and not inside the existing encode processor
  - the new raw dirty-region probe adds an important qualifier:
    - the update metadata itself is not missing
    - what is missing is a backend path that can exploit that metadata without first paying for the full source surface
- stop coupling `partial HDR overlay` validation to encoded sample-buffer HDR signalling
  - `387` showed that the current bridge/runtime probe still has no independent source of overlay-active truth once the main encoded stream becomes SDR
  - the new raw-source attachment probe explains why: current `SLDisplayStream` `x420`/`BGRA` surfaces do not propagate HDR transfer/static-metadata attachments in the first place
  - any future selective-HDR architecture needs a producer-visible overlay-active signal that survives all the way into measurement without reusing full-frame HDR sample metadata
  - `416` closes the next layer of that question too: even after source dirty-region truth survives all the way into the overlay contract, the official score does not move
  - practical consequence: keep the dirty-region/overlay-truth contract as a correctness asset, but do not treat it as a performance lever for the current 120 fps ceiling
- focus on backend/source changes, not more queue churn:
  - expose partial update metadata and drop counts through the capture source runtime
  - treat `raw x420 source cadence` as the gating metric for any new structural experiment
  - stop assuming that moving submit work around will fix the score; experiments `382-385` show that callback/mailbox choreography alone does not beat the keep
  - `417` sharpens that warning: even when ingress restructuring clearly recovers source cadence in host diagnostics, it is still invalid if it violates the current HEVC runtime-probe stability contract
  - investigate a split architecture where the fast base path stays on the source format that preserves cadence and HDR-active regions are injected from a different truth source, instead of forcing whole-surface HDR semantics through every frame
  - practical consequence: source-visible dirty rects, private compositor statistics, or a private display backend are now more promising than any additional VideoToolbox property sweep

### Latest downstream ingress findings

- the next real ceiling is now visible in `Lumen` ingress policy, not just inside MDK
- on `capture processing queue is saturated`, `Lumen` currently escalates transient source pressure
  into decoder resyncs and even session restarts; that makes downstream recovery policy part of the
  measured path
- however, the last four ingress-policy sweeps also show that saturation is not safe to simply
  ignore:
  - `168 / 184d29b4 / 72.74`
    - removing saturation-triggered resync and restart entirely causes backlog-driven startup and
      callback-latency collapse
  - `169 / fd674475 / 73.34`
    - gating saturation recovery on repeated stalled packets still lets startup backlog run away
  - `170 / b7050537 / 81.97`
    - startup-only `request IDR` without queue flush is better, but still leaves too much backlog
      during initial stream bring-up
  - `171 / c1c56248 / 57.63`
    - startup-only light queue flush without the full old resync path amplifies drop churn even more
- the strong new read is that the deepest open problem is startup IDR acquisition under queue
  pressure:
  - full decoder/session resync on every startup saturation is too destructive
  - doing nothing is too weak
  - keyframe-only recovery is directionally better than the other Lumen-side alternatives tried so
    far, which suggests the next iterations should stay focused on startup-specific recovery
    semantics instead of steady-state queue policy
- the newest downstream experiments narrow that further:
  - `172 / 6c8042b2 / 89.79`
    - consumer-side startup latest-wins fast-forwarding is materially better than reset-policy
      tweaks, but not enough on its own
  - `173 / 9a36abd4 / 90.21`
    - fast-forwarding startup backlog and immediately requesting a fresh IDR when no queued
      recovery point survives is the strongest Lumen-side variant so far
  - `174 / bc3d770f / 89.58`
    - gating that path behind observed startup pressure does not improve it further
  - `175 / 7e7da337 / 90.21`
    - producer-side startup capacity clamping ties the best consumer-side result, which points to
      the same underlying shape: startup-specific latest-wins admission works, but still needs a
      lower-overhead integration point to beat the current MDK-only best
  - `176 / eb33378b / 89.17`
    - moving the startup clamp into the Swift bridge and restoring it after the first frame is
      slightly worse than touching the shared ingress directly
  - `177 / 4b50d841 / 81.01`
    - holding the bridge clamp until the first startup key frame is too aggressive and reintroduces
      startup drop churn
  - `178 / c8dd54f8 / 65.38`
    - narrowing the bridge clamp to HEVC-only still collapses startup, so the bridge callback layer
      is not the right integration point for this recovery shape
  - `179 / 16d3f383 / 88.96`
    - teaching the shared ingress itself to keep only the freshest startup frame or freshest queued
      recovery point improves startup latency, but it shaves away too much early progression after
      the first recovery point lands
  - `180 / ea3f97ee / 89.17`
    - preserving the recovery point plus one following frame recovers some early continuity, but it
      still leaves too much performance on the table
  - `181 / 5a1f3db7 / 90.00`
    - widening the shared-ingress startup continuity window to the recovery point plus two following
      frames helps more, but still fails to reach the active best
- current synthesis:
  - startup-specific latest-wins admission remains the strongest downstream idea after the active
    MDK best, but the only versions that stay near viability live at the shared ingress / packet
    consumption boundary
  - the Swift bridge callback layer is now effectively closed for this class of startup recovery
    experiments
  - shared-ingress startup latest-wins is closer to the right layer than the bridge, but preserving
    only a single startup frame is too aggressive; however, even widening that policy to
    `recovery-point + minimal continuity` still tops out below the active best
  - the remaining gap now looks less like a pure ingress-admission problem and more like MDK-side
    early keyframe production / cadence after startup admission has already been cleaned up

## Production session status

The benchmark-only raw `SkyLight` path has now been lifted into production-facing Swift
API surface:

- `MDKSkyLightDisplayStreamSession`
  - raw `SLDisplayStream` frame delivery
  - panel-native sizing by default
- `MDKEncodedCaptureSession`
  - `SLDisplayStream` source
  - optional Metal preprocessing
  - VideoToolbox encoded output via `AsyncThrowingStream<MDKEncodedFrame, Error>`
  - lifecycle/recovery/backpressure surfaced through `AsyncStream<MDKEncodedCaptureSessionEvent>`
  - backpressure through stream buffering policy
  - restart policy for runtime failures

This means the repository no longer depends on benchmark harness code to validate the
core capture + encode mechanism.

### Encoded output path

The encoded production path now:

- emits real encoded `CMSampleBuffer` output through `MDKEncodedFrame`
- carries source display-time / sequence metadata into the output callback
- supports:
  - `HEVC Main10`
  - `H.264`
  - `ProRes Proxy`
    - default production preference now leans toward `x422` 10-bit 4:2:2 capture surfaces instead of `BGRA`
    - this keeps the ProRes path closer to desktop/UI text fidelity goals while avoiding replayd

### HDR signaling status

HDR signaling is now wired into the production `VideoToolbox` path through:

- VT session properties:
  - color primaries
  - transfer function
  - YCbCr matrix
  - HDR metadata insertion mode
  - mastering display color volume
  - content light level info
- propagated `CVPixelBuffer` attachments with matching HDR metadata
- in-process HDR inspection via `MDKEncodedFrame.hdrValidationReport`

Important caveat:

- this validates the encode-path signaling plumbing
- it does not yet prove that the source display content is truly HDR in the current host environment
- a real HDR-capable display is still needed for end-to-end HDR validation

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
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-trace-display <displayID> --sample-duration <seconds> [--with-metal-stimulus] --json`
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-compare-display <displayID> --sample-duration <seconds> --json`
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-series-display <displayID> --sample-duration <seconds> --series-count <count> [--with-metal-stimulus] --json`
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
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-trace-display <displayID> --sample-duration <seconds> [--with-metal-stimulus] --json`

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
- use the replayd producer trace when the goal is to overlap the same passive handshake with a short `sample replayd`
  window and correlate public `SCStream` setup with daemon-side producer evidence in one run

Replayd producer trace specifics:

- the host resolves the current `replayd` PID with `pgrep -x replayd`
- it launches the passive handshake trace on the main actor and overlaps it with an actor-coordinated
  `/usr/bin/sample` invocation against that daemon PID
- the helper intentionally keeps the sample short:
  - launch delay is clamped to `0.25s ... 0.5s`
  - sample duration is clamped to `1.0s ... 1.5s`
  - sample interval stays at `1ms`
- the command exits `0` when it successfully produces the combined report, even if the older
  `passiveTrace.succeeded` field remains `false`
- the compare command runs two back-to-back captures:
  - baseline passive trace
  - passive trace with `MDKHostMetalStimulus`
- the compare report then computes:
  - persistent indicators
  - baseline-only indicators
  - stimulus-only indicators
- the series command runs the same producer trace repeatedly and aggregates indicator match counts by window
- this is still a sampling-density proxy, not a true `Hz` measurement, but it makes it possible to see
  whether producer-side evidence gets denser or more stable under motion
- latest verified compare run on display `auto`, `2s` sample:
  - persistent indicators:
    - `skylight-display-stream`
    - `slcontentstream`
  - baseline-only indicators:
    - `producer-read-queue`
  - stimulus-only indicators: none
  - indicator hit counts:
    - `producer-read-queue`: baseline `2`, stimulus `0`
    - `skylight-display-stream`: baseline `2`, stimulus `5`
    - `slcontentstream`: baseline `1`, stimulus `3`
  - interpretation:
    - the paired sample still does not prove `120-like` producer cadence
    - but it does show a measurable shift in daemon-side producer evidence under stimulus,
      with the visible SkyLight producer edge getting denser while the read-queue sample
      itself was not captured in that short stimulus window

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

Follow-up passive trace after scanning the live `OS_dispatch_source` for an embeddable handler
block:

- `dispatchSourceHandlerInstalledCount=0`
- `dispatchSourceHandlerCallbackEventCount=0`

Interpretation:

- the live fifo-backed `OS_dispatch_source` that sits in front of the wrapper callback does not
  currently expose an obvious writable `void (^)(void)` handler block inside the scanned object
  allocation
- this cuts off the simplest object-local `dispatch source handler block -> wrapper block` hook,
  so the next meaningful reverse-engineering hop is now outside the object:
  - libdispatch-internal source invoke/fire machinery, or
  - the producer-side wakeup path that feeds the fifo before libdispatch fires the source

Follow-up passive trace after installing backtrace-derived libdispatch interposes:

- `dispatchSourceInvokeInterposeAttempted=1`
- `dispatchSourceInvokeInterposeInstalled=1`
- `dispatchSourceInvokeEntryEventCount=0`
- `dispatchSourceLatchAndCallInterposeAttempted=1`
- `dispatchSourceLatchAndCallInterposeInstalled=1`
- `dispatchSourceLatchAndCallEntryEventCount=0`
- `dispatchClientCalloutInterposeAttempted=1`
- `dispatchClientCalloutInterposeInstalled=1`
- `dispatchClientCalloutRQReceiverEntryEventCount=0`

Interpretation:

- the relevant libdispatch frames are still present in the wrapper invoke backtrace, but ordinary
  dyld-based address interpose is not receiving live callbacks for `_dispatch_source_invoke`,
  `_dispatch_source_latch_and_call`, or `_dispatch_client_callout`
- that strongly suggests the remaining scheduling boundary is no longer reachable through simple
  same-process symbol interposition, even though the frames remain symbolicated on sampled stacks
- with the wrapper callback, nested ScreenCaptureKit block, and `__rqReceiverSetSource_block_invoke`
  already localized, the next practical upstream target is now the producer / wakeup side feeding
  the fifo-backed dispatch source rather than another userland callback immediately above it

Live host inspection of the receive handles during a three-second passive trace:

- `fd 3`, `fd 5`, and `fd 7` resolve to `PIPE` endpoints in `lsof -p <MacDisplayKitHost pid>`
- sibling fds `4`, `6`, and `8` are the paired pipe endpoints in the same process

Interpretation:

- the receive handles that libdispatch reports as fifo-backed read sources are concretely realized
  as local pipe pairs in the host process, not named filesystem FIFOs with a recoverable path
- that makes the remaining producer-side question sharper: either the producer is writing through a
  libdispatch-private or non-imported syscall path in-process, or another process/daemon is feeding
  the opposite pipe endpoint through an already-established channel

Follow-up passive trace after interposing `write` / `write_nocancel` on the same images:

- `fifoWriteInterposeEventCount=0`
- `fifoWriteEventCount=0`
- `fifoWriteNoCancelEventCount=0`
- `videoRemoteQueueRecvFDSignalEventCount=0`

Interpretation:

- even though the wakeup handles are real pipes, no imported `write` or `write_nocancel` calls are
  visible in `ScreenCaptureKit`, `CMCapture`, or `libdispatch` during the passive trace window
- combined with the earlier `read`, `dispatch source`, and `dispatch client callout` dead ends, the
  remaining wakeup path is now best modeled as either:
  - a libdispatch- or CoreMedia-internal producer path that bypasses imported write stubs, or
  - a cross-process feed into the paired pipe endpoint that never surfaces as a local write import

Follow-up passive trace after interposing `xpc_fd_dup` / `xpc_dictionary_dup_fd` on the same images:

- `xpcFDInterposeAttempted=1`
- `xpcFDInterposeInstalled=1`
- `xpcFDInterposeInstalledImageCount=3`
- `xpcFDDupEventCount=0`
- `xpcDictionaryDupFDEventCount=0`

Interpretation:

- the host process does not appear to materialize the observed `RecvFd` / `SendFd` queue artifacts by
  calling imported `xpc_fd_dup` or `xpc_dictionary_dup_fd` during the passive trace window
- that cuts off another same-process handoff theory: the fd-bearing queue object is present in the
  host, but the live wakeup path is not exposing itself through imported xpc fd duplication either
- with `dispatch`, `read`, `write`, and xpc fd duplication all eliminated in the host process, the
  next best upstream boundaries are now:
  - `CMCapture`'s xpc request/reply transport (`xpc_pipe_create`, `xpc_pipe_simpleroutine`)
  - local `pipe` creation / duplication in the capture stack
  - the cross-process producer (`replayd`) that brokers those pipe-backed queue endpoints

Follow-up passive trace after interposing `xpc_pipe_create` / `xpc_pipe_simpleroutine`:

- `xpcPipeInterposeAttempted=1`
- `xpcPipeInterposeInstalled=1`
- `xpcPipeInterposeInstalledImageCount=3`
- `xpcPipeCreateEventCount=0`
- `xpcPipeSimpleRoutineEventCount=0`

Interpretation:

- even the xpc pipe transport layer that `CMCapture` imports is not surfacing through ordinary host-side
  dyld interposition during the passive trace window
- that pushes the remaining live handoff candidates down to two sharper buckets:
  - local `pipe` creation / duplication inside the host capture stack
  - cross-process brokering (`replayd` or another producer) before the host ever sees those queue endpoints

Follow-up passive trace after interposing `pipe()` on the same images:

- `pipeInterposeAttempted=1`
- `pipeInterposeInstalled=1`
- `pipeInterposeInstalledImageCount=3`
- `pipeCreateEventCount=0`

Interpretation:

- the host process is not creating the observed queue pipe pairs through an imported `pipe()` call in
  `ScreenCaptureKit`, `CMCapture`, or `libxpc` during the passive trace window
- with `pipe()`, xpc pipe transport, xpc fd duplication, `write`, `read`, and libdispatch fire hooks all
  staying dark in the host, the next meaningful host-side boundary is no longer fd creation at all
- the sharper remaining target is now the mach-port-to-surface handoff (`IOSurfaceLookupFromMachPort`) or
  the cross-process broker (`replayd`) that feeds those queue artifacts before the host starts draining them

Follow-up passive trace after interposing `IOSurfaceLookupFromMachPort` / `IOSurfaceCreateMachPort`:

- `ioSurfaceMachInterposeAttempted=1`
- `ioSurfaceMachInterposeInstalled=1`
- `ioSurfaceMachInterposeInstalledImageCount=3`
- `ioSurfaceLookupFromMachPortEventCount=0`
- `ioSurfaceCreateMachPortEventCount=0`

Interpretation:

- the host process is not surfacing the live queue handoff through imported `IOSurfaceLookupFromMachPort`
  or `IOSurfaceCreateMachPort` either, at least not through ordinary dyld-based interpose on
  `ScreenCaptureKit`, `CMCapture`, or `IOSurface`
- with fd creation, xpc transport, and mach-port-to-surface conversion all dark inside the host, the
  remaining actionable direction is now overwhelmingly cross-process:
  - the broker path in `replayd`
  - or another non-imported/private handoff path below `CMCapture` that the host only sees after the queue is live

Follow-up passive trace after interposing `xpc_connection_create_mach_service` and send APIs:

- `xpcConnectionInterposeAttempted=1`
- `xpcConnectionInterposeInstalled=1`
- `xpcConnectionInterposeInstalledImageCount=3`
- `xpcConnectionCreateMachServiceEventCount=0`
- `xpcConnectionSendEventCount=0`
- `xpcConnectionServiceHistogram={}`

Interpretation:

- the host process is not surfacing the broker path through imported `xpc_connection_*` calls either,
  at least not through ordinary dyld-based interpose on `ScreenCaptureKit`, `CMCapture`, or `libxpc`
- by this point the host-side reverse-engineering picture is highly consistent: the live queue handoff is
  not visible through imported fd duplication, xpc transport, pipe creation, mach-port conversion, or
  xpc connection setup from the host process
- that leaves the next practical reverse-engineering step overwhelmingly cross-process:
  - inspect `replayd` as the broker / producer
  - or attach lower than host-side imported stubs, because the host is only seeing the queue after it is already live

Follow-up passive trace after broadening broker-side interposes to raw `bootstrap_*`,
`xpc_connection_create_from_endpoint`, `xpc_endpoint_create`, `xpc_connection_set_non_launching`,
`xpc_mach_send_create`, and `xpc_mach_send_copy_right`:

- `bootstrapInterposeAttempted=1`
- `bootstrapInterposeInstalled=1`
- `bootstrapInterposeInstalledImageCount=3`
- `bootstrapLookUpEventCount=0`
- `bootstrapCheckInEventCount=0`
- `bootstrapServiceHistogram={}`
- `xpcBrokerInterposeAttempted=1`
- `xpcBrokerInterposeInstalled=1`
- `xpcBrokerInterposeInstalledImageCount=3`
- `xpcConnectionCreateFromEndpointEventCount=0`
- `xpcEndpointCreateEventCount=0`
- `xpcConnectionSetNonLaunchingEventCount=0`
- `xpcMachSendCreateEventCount=0`
- `xpcMachSendCopyRightEventCount=0`

Interpretation:

- host-side passive tracing still does not see the `ScreenCaptureKit` / `CMCapture` broker handoff through
  imported `bootstrap_*`, endpoint-creation, non-launching XPC setup, or Mach-send wrappers
- local dyld-cache inspection still matters here: `CMCapture` imports `_xpc_connection_create_from_endpoint`,
  `_xpc_endpoint_create`, `_xpc_dictionary_extract_mach_recv`, `_xpc_dictionary_set_mach_recv`, and raw Mach/MIG
  symbols, while `ScreenCaptureKit` imports `_xpc_connection_set_non_launching`, `_xpc_mach_send_create`, and
  `_xpc_mach_send_copy_right`
- combining those imports with the all-zero host-side trace strongly suggests the live handoff sits across a
  process boundary, most likely in `replayd`, and only materializes inside the host after the queue is already active
- the next practical reverse-engineering step is therefore no longer another host-side imported stub; it is:
  - `replayd` cross-process observation / disassembly around `SCContentSharingSessionService`
  - or lower Mach/MIG receiver state inside `CMCapture` once the remote queue has already been connected

Follow-up passive trace after swizzling `NSXPCConnection` setup in the host process:

- `nsxpcInitMachServiceEventCount=1`
- `nsxpcInitListenerEndpointEventCount=0`
- `nsxpcResumeEventCount=1`
- `nsxpcSetRemoteObjectInterfaceEventCount=1`
- `nsxpcSetExportedInterfaceEventCount=1`
- `nsxpcServiceHistogram={"com.apple.replayd":1}`
- `firstNSXPCMachServiceName=com.apple.replayd`
- `firstNSXPCRemoteObjectInterface={"className":"NSXPCInterface","present":true,"protocolName":"RPDaemonProtocol"}`
- `firstNSXPCExportedInterface={"className":"NSXPCInterface","present":true,"protocolName":"RPClientProtocol"}`
- `nsxpcRemoteObjectProxyEventCount=0`
- `nsxpcRemoteObjectProxyWithErrorHandlerEventCount=3`
- `nsxpcSynchronousRemoteObjectProxyWithErrorHandlerEventCount=0`
- `firstNSXPCRemoteObjectProxy=<null>`
- `firstNSXPCRemoteObjectProxyWithErrorHandler={"className":"__NSXPCInterfaceProxy_RPDaemonProtocol","present":true}`
- `firstNSXPCSynchronousRemoteObjectProxyWithErrorHandler=<null>`
- `nsxpcInterfaceWithProtocolEventCount=2`
- `nsxpcInterfaceSetClassesEventCount=0`
- `nsxpcInterfaceSetInterfaceEventCount=0`
- `nsxpcInterfaceSetReplyBlockSignatureEventCount=0`
- `nsxpcInterfaceProtocolHistogram={"RPClientProtocol":1,"RPDaemonProtocol":1}`
- `nsxpcInterfaceSelectorHistogram={}`
- `rpDaemonProxySetConnectionEventCount=1`
- `rpDaemonProxyHandleInvocationEventCount=5`
- `rpDaemonProxySelectorHistogram={"startRemoteQueue:streamID:":3}`
- `rpDaemonProxyReplyHistogram={"reply":2,"request":4}`
- `rpDaemonProxyFirstStartRemoteQueueInvocation={"numberOfArguments":4,"queue":{"className":"SCRemoteQueueXPCObject","present":true,"queueType":1,...},"streamID":{"className":"__NSCFString","present":true,"value":"<stream-id>"}}`

Interpretation:

- the host process still does not expose the broker handoff through imported `xpc_connection_create_from_endpoint`,
  `xpc_endpoint_create`, `xpc_connection_set_non_launching`, or `xpc_mach_send_*`
- but the Objective-C layer *does* show a concrete client connection being created against `com.apple.replayd`
- the first remote interface is now concretely identifiable as `RPDaemonProtocol`
- the first exported interface is now concretely identifiable as `RPClientProtocol`
- the host does not request a plain `remoteObjectProxy`, but it *does* request a
  `remoteObjectProxyWithErrorHandler:` object three times during a healthy passive trace
- the first returned proxy is a concrete `__NSXPCInterfaceProxy_RPDaemonProtocol` instance
- the contract setup only materializes as two `interfaceWithProtocol:` calls, one for
  `RPDaemonProtocol` and one for `RPClientProtocol`
- there are no observed `setClasses:...`, `setInterface:...`, or `setReplyBlockSignature:...`
  calls, so the passive path is not building a richer selector/class map through public `NSXPCInterface`
- the host *does* bind one `RPDaemonProxy` connection and then funnels at least five
  `connection:handleInvocation:isReply:` calls through it during the same healthy passive trace
- the first selector that clearly surfaces in that invocation histogram is `startRemoteQueue:streamID:`
- the first `startRemoteQueue:streamID:` request carries an `SCRemoteQueueXPCObject` with `queueType=1`
  and the same `streamID` value later seen on the `SCStream` side
- the outer `SCRemoteQueueXPCObject` pointer does **not** survive into
  `SCStream startRemoteVideoReceiveQueue:` because the local consumer is handed the
  inner `OS_xpc_dictionary` directly
- the inner `remoteQueue` pointer *does* survive that handoff intact:
  `rpDaemonProxyToSCStreamRemoteQueuePointerMatched=1`
- the `streamID` continuity also holds in the same trace:
  `rpDaemonProxyFirstStartRemoteQueueStreamIDMatchesTraceStreamID=1`
- a live `sample replayd 1 1` during passive capture shows the daemon-side producer thread
  `com.apple.coremedia.remotequeue_sender.readqueue` blocked in
  `rqSenderHandleDequeue (in CMCapture) -> read`
- the same `replayd` binary imports
  `_FigRemoteQueueSenderCreate`,
  `_FigRemoteQueueSenderCreateXPCObject`, and
  `_FigRemoteQueueSenderSetMaximumBufferAge`
- the host now exposes a combined command for this same comparison:
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-trace-display <displayID> --sample-duration <seconds> --json`
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-trace-display <displayID> --sample-duration <seconds> --with-metal-stimulus --json`
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-compare-display <displayID> --sample-duration <seconds> --json`
  - `MacDisplayKitHost --experimental-screencapturekit-replayd-producer-series-display <displayID> --sample-duration <seconds> --series-count <count> [--with-metal-stimulus] --json`
- latest verified baseline run from that command captured:
  - `com.apple.coremedia.remotequeue_sender.readqueue`
  - `rqSenderHandleDequeue`
  - `CGYDisplayStreamNotification_server`
  - `_CGYDisplayStreamFrameAvailable`
  - `SLContentStream`
- latest verified `--with-metal-stimulus` run still captured the SkyLight producer edge
  (`CGYDisplayStreamNotification_server`, `_CGYDisplayStreamFrameAvailable`, `SLContentStream`)
  but did not capture `rqSenderHandleDequeue` in that specific sample window
- that makes the new host command the stable way to compare daemon-side producer evidence across
  idle and stimulus conditions without manually invoking `sample replayd`
- the latest `--experimental-screencapturekit-replayd-producer-compare-display auto --sample-duration 2 --json`
  run showed:
  - `producer-read-queue`: baseline `2`, stimulus `0`
  - `skylight-display-stream`: baseline `2`, stimulus `5`
  - `slcontentstream`: baseline `1`, stimulus `3`
  - persistent indicators: `skylight-display-stream`, `slcontentstream`
  - baseline-only indicator: `producer-read-queue`
- the latest `--experimental-screencapturekit-replayd-producer-series-display auto --sample-duration 2 --series-count 2`
  runs showed:
  - baseline:
    - `producer-read-queue`: `[2, 0]`
    - `skylight-display-stream`: `[3, 2]`
    - `slcontentstream`: `[2, 1]`
  - with `--with-metal-stimulus`:
    - `producer-read-queue`: `[2, 8]`
    - `skylight-display-stream`: `[2, 4]`
    - `slcontentstream`: `[3, 4]`
- interpretation:
  - this still does not prove `120-like` cadence
  - but it does show a repeatable increase in producer-side sample density under motion,
    especially on `producer-read-queue`
- `xctrace` follow-up on this machine:
  - short `Time Profiler` and `System Trace` recordings both succeed against `replayd` without extra privileges
  - the most useful template so far is `System Trace`
  - a verified minimal command sequence is:
    - `MacDisplayKitHost --experimental-screencapturekit-replayd-xctrace-display auto --sample-duration 3 --with-metal-stimulus --json`
  - the host command pairs:
    - passive `SCStream` handshake trace
    - `xctrace record --template 'System Trace' --attach replayd --time-limit <N>s`
    - `xctrace export --toc`
    - `xctrace export` of `syscall` and `time-sample` tables
    - filtered `log show --style ndjson --process replayd`
  - current limitation:
    - on the latest verified run, both exported tables came back as schema-only XML
      (`rowCount=0`) even though the `.trace` bundle recorded successfully
    - this means the immediate next step is artifact-first, not table-row-first:
      keep the `.trace` bundle, TOC, table exports, and replayd log together for later bundle-format parsing
  - explicit upstream attach check:
    - `/usr/bin/sample` still cannot inspect `WindowServer` without elevated privileges
    - but `xcrun xctrace record --template 'System Trace' --attach 408 --time-limit 1s --output <trace> --no-prompt`
      does succeed and produces a valid `WindowServer` trace bundle without `sudo`
    - a raw `1s` explicit attach export on this machine produced:
      - `context-switch rowCount=7839`
      - `time-sample rowCount=231`
    - that makes `xctrace`, not `sample`, the viable low-level artifact path for `WindowServer -> replayd`
    - the host now exposes the matching orchestration entry point:
      - `MacDisplayKitHost --experimental-screencapturekit-windowserver-xctrace-display auto --sample-duration 3 --with-metal-stimulus --json`
  - useful bundle paths inside a successful `System Trace` artifact include:
    - `corespace/run1/core/table-manager`
    - `corespace/run1/core/stores/indexed-store-*`
    - `Trace1.run/RunIssues.storedata`
  - latest verified paired run from the new host command showed:
    - passive `SCStream` side still `60hz-like`
      - `sampleBufferEventCount=163`
      - `videoQueueWrapperCallbackCadenceClassification=60hz-like`
    - `xctrace` row export succeeded on this run:
      - `syscall rowCount=3664`
      - `time-sample rowCount=66`
    - a follow-up `3`-second paired run with hot-symbol parsing showed:
      - `systemCall hotSymbolHistogram={"CGYDisplayStreamFrameAvailable":9,"SLContentStream":1,"roEnqueue":1,"roEnqueueSampleBuffer":3}`
      - `timeSample hotSymbolHistogram={}`
      - the same run still logged `261` enqueue failures, all `messageKind=generic-enqueue-error`
    - after adding syscall-row cadence parsing, paired runs showed:
      - `rqSenderHandleDequeue` rows are sampled too sparsely to be useful and collapse into sub-millisecond bursts
      - `roEnqueueSampleBuffer` rows remain `coalesced-or-mixed` rather than `120hz-like`
      - a `6`-second run still only surfaced `4` sampled `roEnqueueSampleBuffer` rows with `140ms`, `173ms`, and `418ms` gaps
      - the same `6`-second run still logged `393` enqueue failures with `60hz-like` spacing
      - after adding syscall-filtered cadence summaries, another `6`-second run showed:
        - `roEnqueueSampleBuffer` total cadence dropped to `insufficient-data` on only `2` sampled rows
        - the sampled syscall histogram for those rows was `{"0x16b73b618":1,"0x16b73bbc0":1}`
        - no `write` rows were sampled for `roEnqueueSampleBuffer`, so `write-only` cadence was unavailable in that window
        - the same run still logged `384` enqueue failures with `60hz-like` spacing
      - after exporting the `context-switch` table from the same host command, a `6`-second run showed:
        - `context-switch rowCount=3060`
        - the dominant replayd `Running` threads were:
          - `2269541` with `eventCount=378`, `cadenceClassification=60hz-like`
          - `2269221` with `eventCount=376`, `cadenceClassification=60hz-like`
        - those thread histograms are dominated by `16.5ms ... 18.0ms` intervals rather than by `~8.3ms`
        - smaller replayd threads can still show sub-millisecond or tiny `120hz-like` bursts, but not at the event counts that dominate producer work
      - after exporting the paired `thread-state` table from the same artifact:
        - the dominant replayd runnable-source summaries now point back to `Main Thread (0x10e8) (WindowServer, pid: 408)`
        - the raw XML contains repeated runnable narratives for those same replayd producer threads:
          - thread `2269541` made runnable by `WindowServer` at `00:00.472.859`, `00:00.524.157`, and `00:01.443.494`
          - thread `2269221` made runnable by `WindowServer` at `00:00.506.274` and `00:01.973.280`
        - replayd threads also wake each other, but `WindowServer` is now a first-class upstream runnable source in the dominant producer path
        - the current replayd-attached `context-switch` export does not carry matching `WindowServer` running rows, so the next artifact needs an explicit `WindowServer` capture rather than more replayd-only parsing
    - replayd unified log emitted repeated producer-side enqueue failures:
      - `_SCRemoteQueue_Enqueue:217 ... err=-19641 opType=3 Error occurred when enqueuing data`
      - the new parser can now summarize those failures directly from the host artifact:
        - `eventCount=278`
        - `errorHistogram={"-19641":278}`
        - `operationHistogram={"3":278}`
        - `messageKindHistogram={"generic-enqueue-error":278}`
        - `remoteQueueHistogram={"0xa543295c0":278}`
        - `senderProgramCounterHistogram={"766532":278}`
        - `imageOffsetHistogram={"766532":278}`
        - `threadHistogram={"2083387":21,"2087226":109,"2087253":148}`
        - interval histogram dominated by `16.0ms` through `20.0ms`
        - `cadenceClassification=60hz-like`
      - a follow-up `3`-second host run with the broadened parser showed the same branch shape:
        - `eventCount=274`
        - `messageKindHistogram={"generic-enqueue-error":274}`
        - no `queue-full` or `client-terminated` events appeared in that window
    - replayd health monitor also reported:
      - `screenframeCount=0`
  - interpretation of that paired run:
    - this is the first artifact-backed signal that the brokered producer path is not merely slow;
      it is hitting `_SCRemoteQueue_Enqueue` failures while the host-side passive trace remains `60hz-like`
    - the hot-symbol parser closes one more gap:
      `opType=3` failures occur in the same paired window where replayd syscall backtraces include
      `roEnqueueSampleBuffer`, which ties the live failure stream directly to sample-buffer producer traffic
    - but the syscall-row cadence parser also shows that the exported `roEnqueueSampleBuffer` rows are too sparse and bursty
      to claim a true `120-like` producer cadence from `xctrace` alone
    - the new `context-switch` parser is much stronger than those sparse syscall samples:
      it observes dominant replayd producer-side running threads directly, and those dominant threads
      still classify as `60hz-like`
    - the new `thread-state` parser closes the next causality gap:
      the same dominant replayd threads are being made runnable by the `WindowServer` main thread,
      so the upstream wake source is now observable instead of inferred
    - the new syscall-filtered view makes that limitation sharper:
      even when the broker logs steady `60hz-like` enqueue failures, `xctrace` may miss `write` wakeups entirely
      and only sample unrelated `roEnqueueSampleBuffer` syscalls in the same window
    - all observed failures in the latest run came from a single replayd callsite offset (`senderProgramCounter=766532`)
      rather than from multiple producer sites
    - static arm64e disassembly of `/usr/libexec/replayd` narrows that offset to the enqueue-error logger region:
      - `0x1000bb1f4 .. 0x1000bb258` logs `"Error occurred when enqueuing data"`
      - `0x1000bb2b8 .. 0x1000bb324` logs `"Cannot Enqueue on an invalid remoteQueue %p"`
      - `0x1000bb384 .. 0x1000bb408` logs `"Queue is full. Resetting...."`
    - the replayd caller at `0x10007ed30 .. 0x10007eeb4` is now identifiable as the producer hot path:
      - it calls `FigRemoteOperationSenderResetIfFullAndEnqueueOperation`
      - `err == -0x411d` takes a dedicated send/sample-buffer error path
      - `err == -0x4119` takes the `"Client terminated the queue"` path
      - other nonzero errors, including the observed `-19641`, fall into the generic enqueue-error logger at `0x1000bb1f4`
    - that makes the next reverse-engineering target sharper:
      the producer-side queue policy / enqueue failure reason inside `replayd` and `CMCapture`,
      especially around `_SCRemoteQueue_Enqueue` and `FigRemoteQueueSender`
    - current strongest reading:
      the `120` ceiling is already lost at or before dominant replayd producer-thread scheduling,
      not only in the public `SCStream` callback path
    - current next upstream split:
      if `WindowServer` display-stream work also proves `60hz-like`, the ceiling is upstream of `replayd`
      if `WindowServer` proves `120-like` while replayd producer threads stay `60hz-like`, the broker queue path remains the choke point
  - this does not yet give cadence, but it creates a repeatable artifact that can be inspected with Instruments
    or mined by parsing the `.trace` bundle directly
- taken together, the brokered producer side now points much more strongly at
  `CMCapture`'s `FigRemoteQueueSender` path than at an ordinary host-side `libdispatch`
  or `NSXPCConnection` helper
- the current request/reply split is `4` requests vs `2` replies in a healthy `1`-second passive trace
- that is the first direct host-side confirmation that the passive `SCStream` capture path is brokered through
  `replayd`, even though the lower imported C shims stay dark
- this shifts the next reverse-engineering target from generic host-side imported stubs to two sharper paths:
  - the next producer-side transition below `rqSenderHandleDequeue`
  - the `FigRemoteQueueSenderCreate*` / `SetMaximumBufferAge` setup path inside `replayd`
  - `replayd` itself, especially `SCContentSharingSessionService` and the session creation / reply path
- 2026-03-21 explicit `WindowServer` `xctrace` attach now completes cleanly through the host command after
  removing PID-specific parsing and replacing the shared `Process` pipe capture with file-backed capture
  to avoid `waitUntilExit()` pipe deadlocks on noisy `xcrun xctrace record` runs
  - paired command:
    - `MacDisplayKitHost --experimental-screencapturekit-windowserver-xctrace-display auto --sample-duration 2`
  - latest artifact summary:
    - `context-switch rows=6102`
    - `syscall rows=9712`
    - `time-sample rows=192`
  - the host formatter now prints the same rich syscall/time-sample summaries for the explicit `WindowServer`
    artifact that the replayd artifact already exposed
  - the context-switch parser no longer assumes `WindowServer pid: 408` or `replayd pid: 740`;
    it now matches by process name so explicit artifacts remain valid across PID churn
  - important interpretation change:
    - the current `120hz-like` bucket is intentionally a `sub-10ms / 120+ candidate` bucket, not an
      exact `120.00 Hz` claim
  - explicit `WindowServer` artifact result:
    - main thread `4328` classified as `120hz-like` with `eventCount=1299`
    - several `coreanimation` and `root_queue` threads also classified as `120hz-like`
  - more importantly, the `WindowServer` syscall backtraces finally expose live upstream display-stream symbols:
    - `hotSymbols={"CGXRunOneServicesPass":6,"CGYDisplayStreamFrameAvailable":1,"displaystream_update":11}`
    - `cadence[displaystream_update]` classified as `120hz-like`
    - `cadence[CGXRunOneServicesPass]` classified as `120hz-like`
    - the `_cgy_DisplayStreamFrameAvailable` hit count is still too sparse to classify by itself
  - this is the strongest current split:
    - upstream `WindowServer` display-stream work shows `sub-10ms / 120+ candidate` behavior
    - dominant replayd producer threads and `_SCRemoteQueue_Enqueue` failures still show `60hz-like`
  - current strongest reading:
    - the choke point is no longer “somewhere in public `SCStream`”
    - it is between `WindowServer` display-stream production and the replayd/CMCapture remote-queue producer path,
      most likely in broker queue policy, enqueue failure handling, or sender-side buffering/coalescing
  - static arm64e disassembly of the sender setup path sharpens that broker-policy reading further:
    - `0x10007e404` calls `FigRemoteQueueSenderCreate`
    - `0x10007e44c .. 0x10007e454` immediately follows with:
      - `ldr x0, [x22, #0x18]`
      - `mov w1, #0x7d0`
      - `bl _FigRemoteQueueSenderSetMaximumBufferAge`
    - that means the sender is configured with a fixed maximum buffer age value of `2000`
    - the exact unit is not proven from disassembly alone, but the value is not dynamic at this callsite
  - static arm64e disassembly of the enqueue wrapper clarifies the explicit error split:
    - `0x10007ed30` calls `FigRemoteOperationSenderResetIfFullAndEnqueueOperation`
    - `err == -16669` (`-0x411d`) takes the dedicated `"Queue is full!"` branch
    - `err == -16665` (`-0x4119`) takes the dedicated `"Client terminated the queue"` branch
    - both branches are separately logged before the wrapper returns
    - the observed runtime log error `-19641` (`0xffffb347`) is neither of those special-case branches
    - so the repeated `_SCRemoteQueue_Enqueue ... err=-19641 opType=3` lines are currently landing in the
      generic `"Error occurred when enqueuing data"` path rather than the explicit queue-full/client-terminated paths
- 2026-03-21 raw `SkyLight` `SLDisplayStream` bypass is now reproducible from the repo through `MacDisplayKitHost`
  - command:
    - `MacDisplayKitHost --experimental-skylight-displaystream-benchmark-display auto --sample-duration 2 --json`
    - `MacDisplayKitHost --experimental-skylight-displaystream-tuning-matrix-display auto --sample-duration 2 --json`
    - optional:
      - `--request-120-like`
      - `--minimum-frame-time <seconds>`
      - `--queue-depth <count>`
      - `--show-cursor`
      - `--with-metal-stimulus`
  - the new host command calls raw `SkyLight` exports directly:
    - `SLDisplayStreamCreateWithDispatchQueue`
    - `SLDisplayStreamStart`
    - `SLDisplayStreamStop`
  - it loads the public `CoreGraphics` property keys dynamically and can request:
    - `kCGDisplayStreamMinimumFrameTime`
    - `kCGDisplayStreamQueueDepth`
    - `kCGDisplayStreamShowCursor`
  - the current `--request-120-like` shorthand now maps to:
    - `minimumFrameTime=1/240`
    - `queueDepth=8`
    - `showCursor=false`
  - latest reproducible `AW2725Q` results:
    - baseline properties (`queueDepth=3`, no minimum-frame-time request):
      - `observedFrameRate=93.45`
      - `cadenceClassification=coalesced-or-mixed`
      - `intervalHistogram={"4.2ms":47,"8.3ms":53,"12.5ms":34,"16.7ms":49,"25.0ms":2,"62.5ms":1}`
    - same baseline with `--with-metal-stimulus`:
      - `observedFrameRate=92.96`
      - `intervalHistogram={"4.2ms":46,"8.3ms":53,"12.5ms":32,"16.7ms":51,"20.8ms":1,"25.0ms":1,"62.5ms":1}`
    - explicit `--request-120-like` properties (`minimumFrameTime=1/120`, `queueDepth=8`):
      - `observedFrameRate=81.34`
      - `intervalHistogram={"4.2ms":19,"8.3ms":66,"12.5ms":40,"16.7ms":18,"20.8ms":6,"25.0ms":3,"29.2ms":5,"33.3ms":3,"54.2ms":1,"58.3ms":1}`
    - `--request-120-like --with-metal-stimulus`:
      - `observedFrameRate=82.56`
      - `intervalHistogram={"4.2ms":19,"8.3ms":70,"12.5ms":40,"16.7ms":19,"20.8ms":5,"25.0ms":2,"29.2ms":5,"33.3ms":3,"54.2ms":1,"58.3ms":1}`
  - latest repo-integrated override runs on the same panel:
    - `--minimum-frame-time 0 --queue-depth 8`:
      - `observedFrameRate=100.31`
      - `cadenceClassification=coalesced-or-mixed`
      - `intervalHistogram={"4.2ms":42,"8.3ms":95,"12.5ms":32,"16.7ms":24,"20.8ms":5,"58.3ms":1,"62.5ms":1}`
    - `--minimum-frame-time 1/240 --queue-depth 3`:
      - `observedFrameRate=100.98`
      - `cadenceClassification=coalesced-or-mixed`
      - `intervalHistogram={"4.2ms":44,"8.3ms":97,"12.5ms":29,"16.7ms":25,"20.8ms":5,"58.3ms":1,"62.5ms":1}`
    - `--minimum-frame-time 0 --queue-depth 8 --with-metal-stimulus`:
      - `observedFrameRate=102.84`
      - `cadenceClassification=120hz-like`
      - `intervalHistogram={"4.2ms":46,"8.3ms":100,"12.5ms":29,"16.7ms":24,"20.8ms":4,"58.3ms":1,"62.5ms":1}`
    - `--minimum-frame-time 1/240 --queue-depth 3 --with-metal-stimulus`:
      - `observedFrameRate=101.94`
      - `cadenceClassification=120hz-like`
      - `intervalHistogram={"4.2ms":46,"8.3ms":98,"12.5ms":29,"16.7ms":24,"20.8ms":5,"58.3ms":1,"62.5ms":1}`
    - later single-run validation on the same panel showed the raw path can go higher:
      - `--minimum-frame-time 0 --queue-depth 8`:
        - `observedFrameRate=118.86`
        - `cadenceClassification=120hz-like`
        - `intervalHistogram={"4.2ms":102,"8.3ms":68,"12.5ms":40,"16.7ms":20,"20.8ms":8}`
      - `--minimum-frame-time 1/120 --queue-depth 8`:
        - `observedFrameRate=93.69`
        - `cadenceClassification=coalesced-or-mixed`
        - `intervalHistogram={"4.2ms":29,"8.3ms":69,"12.5ms":57,"16.7ms":24,"20.8ms":9}`
      - `--minimum-frame-time 1/240 --queue-depth 8` over a longer `5s` window:
        - `observedFrameRate=95.63`
        - `cadenceClassification=120hz-like`
        - `intervalHistogram={"4.2ms":70,"8.3ms":288,"12.5ms":44,"16.7ms":23,"20.8ms":25,"25.0ms":16,"29.2ms":7,"33.3ms":2,"54.2ms":1,"58.3ms":2}`
  - host-only tuning matrix now exists to compare a fixed candidate set without manually running each configuration:
    - command:
      - `MacDisplayKitHost --experimental-skylight-displaystream-tuning-matrix-display auto --sample-duration 2 --json`
      - optional:
        - `--with-metal-stimulus`
    - the first in-process matrix under-reported throughput because reusing the same host process contaminated later runs
    - the matrix now launches a fresh child process per candidate before ranking
    - latest child-isolated matrix results:
      - no stimulus:
        - `bestCandidate=min-frame-240hz-q8`
        - `observedFrameRate=115.65`
        - `cadenceClassification=120hz-like`
      - with Metal stimulus:
        - `bestCandidate=min-frame-240hz-q8`
        - `observedFrameRate=114.43`
        - `cadenceClassification=120hz-like`
  - current interpretation:
    - raw `SLDisplayStream` bypasses a large part of the `replayd/SCStream` ceiling and is now demonstrably capable
      of roughly `115-119 fps` on the current machine, which is materially higher than the brokered host path
    - tuned overrides now lift the same raw path into repeatable `120hz-like` territory, although the interval histogram
      still mixes `4.2ms`, `8.3ms`, and slower buckets rather than collapsing to a pure `8.3ms` band
    - the explicit `minimumFrameTime=1/120` request is currently counterproductive on this panel and lowers throughput,
      while `queueDepth=8` and especially `minimumFrameTime=1/240` with `queueDepth=8` produce materially better results
    - because of that, the `--request-120-like` shorthand has been retuned away from `1/120` and now requests
      the better `1/240 + queueDepth=8` combination
    - that shifts the next optimization target from `SCStream` tuning to raw `SkyLight` display-stream property tuning
      and lower-level `SLContentStream` / `CGYDisplayStreamFrameAvailable` exploration
- 2026-03-21 raw `SkyLight` processing benchmarks now run directly from the repo on top of the bypass path
  - commands:
    - `MacDisplayKitHost --experimental-skylight-displaystream-benchmark-display auto --sample-duration 3 --request-120-like --processing-mode metal-bind --json`
    - `MacDisplayKitHost --experimental-skylight-displaystream-benchmark-display auto --sample-duration 3 --request-120-like --processing-mode metal-copy --json`
    - `MacDisplayKitHost --experimental-skylight-displaystream-benchmark-display auto --sample-duration 3 --request-120-like --processing-mode vt-encode --json`
    - `MacDisplayKitHost --experimental-skylight-displaystream-processing-matrix-display auto --sample-duration 2 --json`
  - the host now has a child-process isolated processing matrix for:
    - `none`
    - `metal-bind`
    - `metal-copy`
    - `vt-encode`
    - `vt-encode-h264`
  - current ranking order is:
    - `meets120LikeTarget`
    - cadence classification
    - effective output frame rate
    - processed-frame ratio
    - complete-frame count
  - one invalid measurement pattern is now understood:
    - running two raw `SLDisplayStream` benchmarks in parallel on the same display badly contaminates throughput
    - comparisons must use either a single sequential command or the child-process matrix
- 2026-03-21 the raw `vt-encode` path no longer fails with `VTCompressionSessionEncodeFrame ... -12902`
  - the original failure was reproduced outside the repo with a tiny Swift script:
    - `CVPixelBufferCreateWithIOSurface(...)` was **not** the root cause
    - `VTCompressionSessionEncodeFrame(...)` returns `-12902` when the session is created with `outputCallback=nil`
    - the same wrapped IOSurface succeeds immediately when the session uses a non-`nil` output callback
  - this matches the SDK contract in `VTCompressionSession.h`:
    - `outputCallback` may only be `NULL` when the caller uses `VTCompressionSessionEncodeFrameWithOutputHandler`
    - it is not valid to pair `outputCallback=nil` with `VTCompressionSessionEncodeFrame`
  - `MacDisplayKit` now uses a non-`nil` callback and Apollo-like session properties for the raw `vt-encode` benchmark
  - latest raw `vt-encode` runs on the current machine show:
    - `processingFailureCount=0`
    - `processedFrameRatio=1`
    - the raw `SLDisplayStream` surface reaches the encoder as standard `420v`
  - current interpretation:
    - the `vt-encode` blocker has moved from `session contract` to `throughput`
    - zero-copy submit is viable now, but the next performance gain depends on keeping capture fast while submit/encode work runs off the raw callback path
- 2026-03-21 raw processing selection is now split into:
  - a `none` control that measures the raw ceiling but is not eligible as the default processed winner
  - processed candidates ranked by:
    - `meets120LikeTarget`
    - cadence classification
    - processed frame rate
    - processed frame ratio
    - complete-frame count
  - the raw tuning matrix now also includes `1/120 + queueDepth=3` as a control so `1/120` can be judged independently of deep queueing
- 2026-03-21 the `vt-encode` submit hot path was trimmed further
  - per-frame summary bookkeeping no longer hops through an actor and blocks the serial encode queue
  - the benchmark now keeps queue-confined `VT` counters and snapshots them during `finalize()`
  - `CVPixelBufferCreateWithIOSurface(...)` wrappers are now cached per live `IOSurfaceID` inside the active session
  - latest child-process processing matrix on the current machine selected:
    - `vt-encode/min-frame-240hz-q8`
    - `processedFrameRate≈139.37`
    - `cadenceClassification=120hz-like`
  - single ad-hoc raw runs outside the child-process matrix are still noisy after prior raw runs and should not be treated as authoritative without isolation
- 2026-03-21 the raw `vt-encode` benchmark now records actual encoder output callback counts separately from submit success
  - result fields:
    - `videoEncoderCodec`
    - `outputCallbackCount`
    - `completedOutputFrameCount`
    - `completedOutputFrameRate`
    - `completedOutputFrameRatio`
    - `outputCallbackStatusHistogram`
    - `outputCallbackLatencyHistogram`
    - `minOutputCallbackLatencyMilliseconds`
    - `maxOutputCallbackLatencyMilliseconds`
  - the intent is to separate:
    - `submit throughput` (`processedFrameCount`)
    - `encoder drain/output throughput` (`completedOutputFrameCount`)
  - the callback/refcon wiring bug is now fixed:
    - `VTCompressionSessionCreate(... refcon: self ...)` is now read from the first callback argument
    - per-frame submission tokens are retained through `sourceFrameRefcon`
    - submit-to-callback latency is now measured at callback receipt time before queue handoff
  - current direct raw runs on the machine show:
    - `vt-encode` / `hevc`
      - `processedFrameCount=27`
      - `completedOutputFrameCount=27`
      - `completedOutputFrameRate≈8.87`
      - `videoToolboxUsingHardwareEncoder=true`
      - latency range `24.147ms..182.691ms`
    - `vt-encode-h264`
      - `processedFrameCount=116`
      - `completedOutputFrameCount=116`
      - `completedOutputFrameRate≈37.85`
      - `videoToolboxUsingHardwareEncoder=unknown`
      - latency range `294.050ms..688.547ms`
  - current interpretation:
    - the benchmark can now distinguish `submit accepted` from `encoder drained`
    - the current raw bottleneck is real encoder throughput, not missing output callbacks
    - `H.264` is materially faster than current `HEVC` settings on this host at `5120x2880 420v`
    - unsupported hardware-only codecs are no longer exposed as supported processing modes in `MacDisplayKit`
- 2026-03-21 the raw VT path now stages frames through a Metal-backed IOSurface pool before encode submit
  - the reason for the experiment was source-surface coupling:
    - direct raw `vt-encode` was still encoding the original `SLDisplayStream` IOSurfaces
    - callback counts tracked encoder drain too closely, which strongly suggested source-surface reuse/backpressure
  - current staged results on the machine:
    - `vt-encode` / `hevc`
      - direct path had previously landed around `8.87 fps`
      - staged path now lands around `37.83 fps`
      - this strongly suggests the old `HEVC` path was throttled by source-surface ownership as well as encode cost
    - `vt-encode-h264`
      - direct path had previously landed around `37.85 fps`
      - staged path landed around `30.69 fps`
      - this points to a different ceiling: the extra Metal staging work does not help the faster `H.264` encoder on this host
  - current interpretation:
    - source-surface backpressure was real, but removing it is not sufficient for `120-like` encode throughput
    - the remaining ceiling is now codec-specific encoder throughput at `5120x2880`
    - the next optimization target is a custom `IOSurface -> Metal -> encoder` path that can trade staging cost against encode throughput more deliberately than the current generic blit pool
- 2026-03-21 the raw VT path now supports `Metal downscale-2x -> encoder` and more aggressive low-latency rate-control tuning
  - configuration changes:
    - new processing modes:
      - `vt-encode-downscale-2x`
      - `vt-encode-h264-downscale-2x`
      - `vt-encode-prores-proxy-experimental`
    - encoder target dimensions are now derived from the preprocess strategy instead of always matching the source `IOSurface`
    - unsupported hardware-only codecs have been removed from the runtime processing matrix
    - the `ProRes Proxy` experimental processing mode is now exposed as a non-default processing option
    - `H.264` now requests `kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel`
    - the staged encoder pool now starts from `kVTCompressionPropertyKey_VideoEncoderPixelBufferAttributes` when available, instead of using only generic `CVPixelBuffer` attributes
    - the session now also tries:
      - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` for `H.264`
      - `AverageBitRate` / `DataRateLimits` only for codecs that support them
      - `MaxKeyFrameIntervalDuration`
      - `ReferenceBufferCount` only for codecs that support it
      - `kVTCompressionPropertyKey_PixelBufferPoolIsShared` and `kVTCompressionPropertyKey_RecommendedParallelizationLimit` are captured as diagnostics
  - current measured behavior on this host:
    - raw `SLDisplayStream` + no processing under the current motion sample:
      - `observedFrameRate≈37.07`
    - raw `SLDisplayStream` tuning matrix under the current motion sample:
      - `baseline-q3` is the best candidate at `observedFrameRate≈41.39`
      - the current `request-120-like` shorthand (`min-frame-240hz-q8`) is slower on this machine state at `observedFrameRate≈36.36`
    - `vt-encode-downscale-2x` / `hevc` with motion stimulus:
      - `processedFrameRate≈37.73`
      - `completedOutputFrameRate≈37.73`
      - `videoToolboxPixelBufferPoolIsShared=true`
      - `videoToolboxRecommendedParallelizationLimit=1`
      - callback latency is now mostly clustered around `5.3ms..5.6ms`, with a smaller tail out to `33.8ms`
      - in the current machine state this keeps the encode path effectively at the raw capture ceiling
    - `vt-encode-prores-proxy-experimental` with motion stimulus:
      - `processedFrameRate≈35.99`
      - `completedOutputFrameRate≈35.50`
      - `videoToolboxUsingHardwareEncoder=true`
      - `videoToolboxPixelBufferPoolIsShared=false`
      - callback latency is mostly `7.8ms..8.1ms`
      - this makes `ProRes Proxy` a viable experimental zero-copy path, but it is still slightly below the current raw ceiling
    - `vt-encode-h264-downscale-2x` with motion stimulus:
      - `processedFrameRate≈34.27`
      - `completedOutputFrameRate≈16.89`
      - `outputCallbackCount=70` with `noErr`, but only about half of callbacks carried an emitted sample buffer
      - moving `H.264` to `ConstrainedBaseline` removed the old `-12915` full-resolution failure pattern, but emitted output is still gated well below callback completion
  - current interpretation:
    - `HEVC downscale-2x` is now the best-behaved custom `IOSurface -> Metal -> encoder` path in the current machine state, because it holds the raw ceiling and drains every callback
    - `ProRes Proxy` is worth keeping as an experimental option precisely because Apple’s hardware path is speed-oriented and it now tracks raw capture closely enough to compare against `HEVC`
    - `H.264` still needs separate tuning; the remaining problem is emitted-sample gating, not missing callbacks or missing hardware acceleration setup
    - the next leverage is not “more public `SCStream` work”; it is better raw `SLDisplayStream` auto-tuning plus codec-specific encoder tuning on top of that raw winner
- 2026-03-21 raw `SLDisplayStream` underperformance on the current host state was traced to a stale `request-120-like` shorthand more than to the raw path itself
  - fresh measurements on the current machine state:
    - `minimumFrameTime=0`, `queueDepth=3`:
      - `observedFrameRate≈65.84`
      - `cadenceClassification=120hz-like`
    - `minimumFrameTime=0`, `queueDepth=8`:
      - `observedFrameRate≈48.44`
      - `cadenceClassification=coalesced-or-mixed`
    - `minimumFrameTime=1/240`, `queueDepth=3`:
      - `observedFrameRate≈93.26`
      - `cadenceClassification=coalesced-or-mixed`
    - `minimumFrameTime=1/240`, `queueDepth=8`:
      - `observedFrameRate≈46.11`
      - `cadenceClassification=coalesced-or-mixed`
  - current interpretation:
    - the raw `SkyLight` path itself is still capable of `90+ fps` on this host
    - the old `request-120-like` shorthand was stale because it still requested `queueDepth=8`
    - on the current `5120x2880 @ 240Hz` scaled desktop, `queueDepth=8` correlates with a large drop in raw callback cadence
    - concurrent `WindowServer`/`ColorSync` load is still worth tracking, but the first concrete fix is to retune the shorthand to `min-frame-240hz-q3`
- 2026-03-21 raw `SLDisplayStream` now resolves panel-native dimensions by default, while also allowing explicit output-dimension overrides
  - mode inventory on `AW2725Q` confirms:
    - current scaled mode reports `5120x2880` backing at `2560x1440 @ 240Hz`
    - panel-native mode inventory still tops out at `3840x2160 @ 240Hz`
  - the benchmark now defaults to the panel-native mode dimensions rather than blindly following the scaled backing size
  - explicit comparison under the current host load with `request-120-like + q3 + Metal stimulus`:
    - `requestedOutputDimensions=3840x2160` -> `observedFrameRate≈36.76`
    - `requestedOutputDimensions=5120x2880` -> `observedFrameRate≈36.86`
  - current interpretation:
    - using panel-native dimensions is the correct default policy for a generic display kit
    - but the present `~37 fps` ceiling is not explained by the `3840 vs 5120` choice alone
    - the dominant current limiter remains host compositor/color-management load, not just the stream's destination dimensions
- 2026-03-21 the custom `BGRA -> Metal -> x420 -> HEVC Main10` path is now the default raw `vt-encode` fast path, and the output-drain accounting bug is fixed
  - implementation changes:
    - raw `SLDisplayStream` processing benchmarks now default to `32BGRA` source frames instead of pre-requesting bi-planar input
    - `MDKVideoToolboxEncodingProcessor` now asks each codec for its preferred encoder input format
    - `HEVC` therefore stages raw `BGRA` through the custom Metal converter into `x420` before `VTCompressionSessionEncodeFrame(...)`
    - the `dispatch_group` output-drain accounting was reordered so `enter()` always happens before `VTCompressionSessionEncodeFrame(...)`, with a compensating `leave()` on synchronous submit failure
  - current direct measurement on the host:
    - command:
      - `MacDisplayKitHost --experimental-skylight-displaystream-benchmark-display auto --sample-duration 2 --minimum-frame-time 0 --queue-depth 3 --processing-mode vt-encode --json`
    - result:
      - `observedFrameRate≈128.68`
      - `processedFrameRate≈128.68`
      - `completedOutputFrameRate≈122.30`
      - `completedOutputFrameCount=249`
      - `completedOutputFrameRatio≈0.95`
      - `cadenceClassification=120hz-like`
      - `videoToolboxColorConversionMode=custom`
      - `videoToolboxColorConversion=0x42475241->0x78343230`
      - `videoToolboxEncoderInputPixelFormat=0x78343230`
      - `videoToolboxOutputDrainWait=success`
  - current interpretation:
    - the old `~8 fps` `HEVC` result was no longer representative after the custom Metal color conversion and corrected output-drain accounting
    - raw `HEVC Main10` on the panel-native `3840x2160` path is now finally in the `4K120HDR` target range
- 2026-03-21 framework-facing raw tuning is now exposed as a reusable configuration surface, and auto-tuned raw candidate selection penalizes stall-heavy winners
  - implementation changes:
    - `MDKSkyLightDisplayStreamConfiguration` now wraps the raw `minimumFrameTime`/`queueDepth` tuning plus optional output sizing and pixel-format overrides
    - raw `SkyLight` benchmark + processing entry points accept the shared configuration surface instead of separate argument lists
    - host-side `--auto-tune-raw` now chooses from processing-mode-specific candidate sets and carries the chosen raw winner into the final processing benchmark
    - raw tuning and processing matrix ranking now penalize `>16ms`, `>33ms`, and `>100ms` stalls before preferring burstier cadence labels
  - current direct measurements on the host:
    - `HEVC + auto-tune-raw` picked `baseline-q3`
      - `autoTunedRawObservedFrameRate≈138.27`
      - `completedOutputFrameRate≈39.65`
      - `stallCountOver16Milliseconds=51`
      - `stallCountOver33Milliseconds=37`
    - `ProRes Proxy + auto-tune-raw` picked `baseline-q2`
      - `autoTunedRawObservedFrameRate≈75.50`
      - `completedOutputFrameRate≈56.98`
      - `stallCountOver16Milliseconds=41`
      - `stallCountOver33Milliseconds=32`
  - current interpretation:
    - the framework can now surface queue-depth selection to Apollo instead of hiding it inside benchmark-only presets
    - on the current loaded host, `ProRes Proxy` is still below the realtime floor but is less stall-heavy than full-resolution `HEVC`
    - raw auto-tuning now avoids selecting unstable `120hz-like` burst patterns when they hide materially worse stall behavior
- 2026-03-21 the `VT` path now defaults to codec-friendly capture pixel formats, keeps detached staging for hardware encoders, and uses the retuned `request-120-like` shorthand
  - implementation changes:
    - host-side processing benchmarks now infer the raw capture pixel format from the encoder mode instead of defaulting every processing run to `BGRA`
    - `HEVC` therefore auto-tuned against `x420` raw capture, while `ProRes Proxy` stays on `BGRA`
    - direct submission of capture-owned `IOSurface`s into `VTCompressionSession` was reverted for `HEVC`/`ProRes`; detached staging remains the default because direct submission collapsed the raw source cadence behind output-callback ownership
    - the raw `request-120-like` shorthand and the reusable raw tuning advisor now point at the retuned queue-depth-1 candidate instead of the stale queue-depth-3/8 era assumptions
  - current direct measurements on the host:
    - `HEVC` auto-tuned raw benchmark now requests `0x78343230` (`x420`) by default and currently picks `baseline-q3`
      - `autoTunedRawObservedFrameRate≈118.16`
      - `completedOutputFrameRate≈97.85`
      - `completedOutputFrameRatio=1.0`
    - explicit `HEVC q1/x420` under current host load:
      - `completedOutputFrameRate≈91.31`
    - explicit `HEVC q3/x420` under current host load:
      - `completedOutputFrameRate≈104.33`
    - `ProRes Proxy` auto-tuned raw benchmark now stays on `BGRA` and currently picks `baseline-q3`
      - `autoTunedRawObservedFrameRate≈103.00`
      - `completedOutputFrameRate≈107.66`
      - `completedOutputFrameRatio=1.0`
  - current interpretation:
    - the old auto-tuned `HEVC≈40 fps` result was mostly a bad default-capture-format problem; `x420` is now the correct default for the `HEVC` path
    - under the current `WindowServer/ColorSync` load, `q3` is outperforming `q1` for `HEVC`, so queue depth must stay configurable and cannot be hardcoded globally
    - the remaining `HEVC` ceiling is no longer a dropped-output problem; it is source slowdown while processing is active
- 2026-03-21 detached staging still pays a per-frame setup cost, so the processor now caches source `MTLTexture` bindings by capture-surface identity and reduces pool minimum pressure without reducing the slot ceiling
  - implementation changes:
    - source `MTLTexture` arrays are now cached per `surfaceID` + plane descriptor set instead of being rebuilt on every frame
    - the `VT` staging pool still allows up to `128` inflight staged slots, but the pool's minimum-buffer count is now capped at `12` to avoid overstating pressure on `CVPixelBufferPool`
  - current interpretation:
    - this does not yet eliminate the `HEVC` source slowdown under current system load, but it keeps the safe detached-staging design and removes one obvious per-frame setup cost while avoiding the slot-exhaustion regression seen when the total inflight slot cap itself was lowered
- 2026-03-21 the framework defaults and tuning advisor now track output-oriented winners instead of stale raw-only assumptions
  - implementation changes:
    - `MDKSkyLightDisplayStreamConfiguration.panelNative()` now defaults to `baseline-q2` instead of the old `request-120-like` shorthand
    - `HEVC/H.264` and `ProRes Proxy` tuning advisors now prioritize `q2` ahead of `q1`
    - host-side `--auto-tune-raw` for processing modes now benchmarks the actual processing candidates and selects the winner from `effectiveOutputFrameRate`/stall behavior instead of carrying over a raw-only winner
    - the staged `CVPixelBuffer` wrapper is created before the Metal completion handler closes over it, so the completion path no longer captures the whole staging slot object
  - current direct measurements on the host:
    - explicit `HEVC x420`:
      - `q1` -> `completedOutputFrameRate≈104.51`
      - `q2` -> `completedOutputFrameRate≈129.78`
      - `q3` -> `completedOutputFrameRate≈127.22`
    - explicit `ProRes Proxy BGRA`:
      - `q1` -> `completedOutputFrameRate≈105.40`
      - `q2` -> `completedOutputFrameRate≈127.67`
      - `q3` -> `completedOutputFrameRate≈97.64`
  - current interpretation:
    - the best current full-output queue depth is `q2`, not the earlier `q1` shorthand and not the older `q3` default
    - Apollo-facing defaults should therefore use `q2`, while the framework still exposes the full tuning surface for callers that want to override it explicitly
    - multi-candidate auto-tuning remains useful as a diagnostic tool, but a long sweep can perturb host load enough that the fixed `q2` default is safer for the first production integration
    - encoder frame-rate hints must stay decoupled from raw `minimumFrameTime`; on this host, `q2 + minFrameTime=1/240` dropped both `HEVC` and `ProRes Proxy` to roughly `62 fps` before the fix, and even after restoring the encoder hint to `120` the same raw request still only reached about `78 fps`
    - the practical production default is therefore `baseline-q2` with `minimumFrameTime=0`, while `request-120-like` remains an experimental raw-stream diagnostic, not the framework's first-choice production preset
- 2026-03-21 the production-facing framework surface no longer exposes the raw `minimumFrameTime` hint
  - implementation changes:
    - `MDKSkyLightDisplayStreamConfiguration` now exposes `queueDepth`, `showCursor`, output sizing, and pixel-format overrides only
    - the `panelNative()` convenience now maps directly to the stable `q2` default without carrying a raw tuning candidate object
    - `HostCommandLine` no longer accepts public raw `minimumFrameTime` or `request-120-like` overrides on the main raw benchmark command; benchmark internals still retain them for tuning-matrix diagnostics
  - current interpretation:
    - Apollo-facing configuration should treat raw `minimumFrameTime` as a private benchmark knob, not a production policy input
- 2026-03-22 the production encoded session now exposes a direct callback consumer path and defaults its production presets to the output-oriented winners
  - implementation changes:
    - `MDKEncodedCaptureConfiguration.panelNative(...)` now defaults to `queueProfile = .q2`
    - `ProRes Proxy` production capture now defaults to `BGRA`, matching the current text/UI-oriented winner
    - `MDKEncodedCaptureSession` now supports `start(callbacks:)` and `installCallbacks(_:)` in addition to the existing `AsyncThrowingStream<MDKEncodedFrame, Error>` path
    - host-side encoded-session diagnostics now accept `--consumer-mode stream|callback`
    - `stop()` now yields to drain deferred callback deliveries before returning, so `statistics.emittedFrameCount` stays aligned with direct callback consumption instead of under-reporting the final frames
  - current direct measurements on the host:
    - `HEVC q2 + callback consumer`:
      - `observedOutputFrameRate≈90.0`
      - `capturePixelFormat=0x78343230` (`x420`)
      - `statistics.emittedFrameCount` now matches the callback-consumed frame count at stop
    - `HEVC q2 + stream consumer`:
      - `observedOutputFrameRate≈45.0`
      - same source/codec settings as the callback run
      - this isolates the remaining production overhead to the stream delivery path rather than the raw encoder path
    - `HEVC q2 + HDR10 + callback consumer`:
      - `observedOutputFrameRate≈66.0`
      - encoded sample summary included `CVImageBufferColorPrimaries=ITU_R_2020`, `CVImageBufferTransferFunction=SMPTE_ST_2084_PQ`, `CVImageBufferYCbCrMatrix=ITU_R_2020`, `MasteringDisplayColorVolume`, and `ContentLightLevelInfo`
    - `ProRes Proxy q2 + callback consumer`:
      - `observedOutputFrameRate≈61.0`
      - `capturePixelFormat=0x42475241` (`BGRA`)
    - `HEVC q2 + callback consumer + Metal stimulus`:
      - `observedOutputFrameRate≈75.0`
    - `ProRes Proxy q2 + callback consumer + Metal stimulus`:
      - `observedOutputFrameRate≈85.0`
  - current interpretation:
    - `Apollo` can consume encoded frames directly through callbacks without routing every frame through the stream consumer path
    - the stream consumer path remains useful for integration tests, diagnostics, and simpler downstream apps
    - under current host load, the callback consumer path is materially better than the stream path for `HEVC`
    - host-side production diagnostics now verify encoded-session HDR signaling on the callback path without relying on the benchmark harness
    - `HEVC Main10 q2 + x420` and `ProRes Proxy q2 + BGRA` remain the production baseline candidates, but both are still sensitive to current `WindowServer/ColorSync` load and should be rechecked under cleaner host conditions before treating the latest numbers as stable ceilings
    - the current production gap to the benchmark harness is now concentrated in consumer-delivery overhead and host compositor load, not in missing callback drain or broken stop semantics
