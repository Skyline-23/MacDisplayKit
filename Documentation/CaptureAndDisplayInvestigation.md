# Capture And Display Investigation

This document is the working record for macOS display, capture, HDR, and encoded-capture
performance work in `MacDisplayKit`.

It replaces ad hoc investigation logs with a shorter operational summary:

- what the repository is trying to achieve
- what is already known
- what has worked
- what has clearly failed
- where the next experiments should concentrate

The full experiment ledger still lives downstream in Lumen `results.tsv`. This document keeps only
the findings that should influence future work.

## Scope

- repo: `MacDisplayKit`
- downstream target:
  - `3512x2290`
  - `120 fps`
  - codecs: `hevc`, `prores-proxy`
- hard constraints:
  - no implicit downscale
  - no SDR fallback during active interaction
  - partial HDR overlay must remain enabled
  - no new dependency additions for optimization work

## Current Status

### Production-facing capture surface

`MacDisplayKit` currently exposes two production session layers:

- `MDKSkyLightDisplayStreamSession`
  - raw `SLDisplayStream` frame delivery
  - panel-native sizing by default
  - intended for consumers that want direct `IOSurface` access
- `MDKEncodedCaptureSession`
  - raw `SkyLight` source
  - optional Metal preprocessing
  - VideoToolbox encoded output
  - direct callback path through `MDKEncodedCaptureCallbacks`
  - stream path through `AsyncThrowingStream<MDKEncodedFrame, Error>`
  - lifecycle / recovery / backpressure events through `AsyncStream<MDKEncodedCaptureSessionEvent>`

### Encoded-path capabilities

The encoded path currently supports:

- `HEVC Main10`
- `H.264`
- `ProRes Proxy`

HDR signaling is wired through:

- VideoToolbox color-primaries metadata
- transfer-function metadata
- YCbCr-matrix metadata
- HDR metadata insertion mode
- mastering-display metadata
- content-light metadata
- matching `CVPixelBuffer` attachments
- in-process verification through `MDKEncodedFrame.hdrValidationReport`

Important caveat:

- this validates encode-path signaling
- it does not by itself prove end-to-end HDR source correctness on every host

## Current Best Autoresearch Result

Current best downstream result:

- experiment: `104`
- MDK commit: `95a1f6b`
- score: `91.36`

Best measured output:

- HEVC:
  - `RUNTIME_SCORE_HEVC=66.36`
  - `frames=47`
  - `startup_ms=161.201`
  - `avg_callback_latency_ms=12.606`
  - `max_callback_latency_ms=32.726`
- ProRes Proxy:
  - `RUNTIME_SCORE_PRORES_PROXY=67.81`
  - `frames=81`
  - `startup_ms=111.99`
  - `avg_callback_latency_ms=8.048`
  - `max_callback_latency_ms=13.782`

### Current kept stack

The current keep is cumulative:

1. lower high-refresh HEVC low-latency bitrate ceiling from `200 Mbps` to `192 Mbps`
2. raise high-refresh HEVC `ExpectedFrameRate` / `ExpectedDuration` hints to `240 Hz`
3. clamp high-refresh callback-only HEVC pending depth to `2`
4. coalesce small `SkyLight` dirty updates at the source
5. let the first small dirty update pass, then treat repeated small updates as a burst

## What Is Working

### 1. Source freshness wins

The biggest gains came from reducing redundant work before it entered the HEVC path:

- pending-depth clamp for callback-only high-refresh HEVC
- source-side small-dirty coalescing
- burst-gated coalescing that preserves the first meaningful partial update

Interpretation:

- stale work is more expensive than slightly tighter producer admission
- source admission quality matters more than downstream cleanup

### 2. HEVC responds to pacing hints, not aggressive quality tweaks

Two HEVC changes consistently helped:

- `192 Mbps` low-latency bitrate ceiling
- `240 Hz` `ExpectedFrameRate` / `ExpectedDuration` hints

Interpretation:

- the current limiting path is more cadence-sensitive than image-quality-sensitive
- the encoder wants a slightly more aggressive timing expectation, but not a radically different
  rate-control regime

### 3. Partial HDR can remain enabled without becoming the main limiter

The current best already preserves partial HDR overlay.

Interpretation:

- partial HDR correctness is compatible with the current performance keep
- richer HDR overlay metadata transport has not yet been the main score lever

## Closed Or Low-Value Directions

The following directions have been tried enough that they should be treated as low priority unless a
new structural reason appears.

### HEVC quality / bitrate micro-tuning

Discarded examples:

- bitrate `188 Mbps`
- bitrate `196 Mbps`
- explicit quality on `120 Hz`
- target quality `0.34`
- zero lookahead

Reading:

- HEVC quality / rate-control micro-tuning has not beaten the current cadence-oriented keep
- some variants destabilize startup outright

### More aggressive VideoToolbox pacing / buffering knobs

Discarded examples:

- `300 Hz` frame-rate hints
- `300 Hz` idle replay
- `MaxFrameDelayCount=1`
- `ReferenceBufferCount=0`
- low-latency rate control at `120 Hz`

Reading:

- `240 Hz` is currently the useful pacing sweet spot
- pushing harder tends to regress startup or overall stability

### Late mailbox / prune logic

Discarded examples:

- latest-frame mailbox
- saturation-only latest-frame overflow
- stale queued HEVC prune on saturation
- async-only HEVC handoff
- serial HEVC processing queue

Reading:

- once redundant work is already admitted into the wrong queue, downstream pruning does not recover
  enough value

### Queue-profile and backend swaps

Discarded examples:

- alternate `q2` / `q3` bootstrap preference variants
- forced private `IOSurface` backend for high-refresh HEVC

Reading:

- the current best path still prefers `SkyLight`
- changing the bootstrap or backend alone has not solved the limiting HEVC path

### Over-tuning the source burst gate

Discarded examples:

- dirty threshold `24%`
- dirty threshold `15%`
- shorter or longer burst windows
- region clustering
- max-dimension guard
- third-update-only suppression
- preserving burst state across replay

Reading:

- the source burst gate has a narrow sweet spot
- the keep is not generic coalescing; it is a specific first-update-pass plus repeated-burst gate

### Replay split and richer partial-HDR transport

Discarded examples:

- splitting `SkyLight` replay from HEVC re-encode
- replay sample-buffer copy with fresh timing
- transporting reduced dirty rects into per-frame partial HDR overlay metadata

Reading:

- architecturally plausible, but not currently score-limiting

### Lumen-side ingress semantics and forwarding slack

Discarded examples:

- treating source saturation as fully recoverable
- collapsing repeated saturation resyncs to a single resync
- startup-only deferred source overflow handoff
- adding one extra `120 Hz HEVC` bridge forwarding slot
- suppressing startup-only HEVC saturation events

Reading:

- ingress churn is visible in logs
- but changing only bridge semantics or forwarding slack has not beaten the producer-side keep

## Current Bottleneck Reading

The strongest current reading is:

- the remaining limit is early source-to-processor-to-encoder cadence inside `MacDisplayKit`
- the highest-value work is still above downstream transport policy
- first stable HEVC submit cadence matters more than bridge queue slack

Observed downstream log patterns still show:

- `Source frame dropped before processing because the capture processing queue is saturated.`
- `core-forwarder-overflow`
- repeated ingress restarts after saturation bursts

But the experiments so far suggest these are amplifiers, not the best optimization surface.

## Condensed Capture Investigation Findings

### Public ScreenCaptureKit path

Useful durable conclusion:

- the public `SCStream` path does not behave like a clean steady `120 Hz` source on the tested
  hosts
- even with visible motion, cadence remained mixed or coalesced rather than clearly `120hz-like`

Interpretation:

- the limiting policy is closer to compositor / WindowServer handoff than to pure encode cost

### Lower-path queue investigation

Useful durable conclusion:

- lower private queue setup is real and observable
- but multiple passive and active queue probes either produced no better cadence or interfered with
  public delivery
- the live local `_videoReceiveQueue` drain callback was informative, but it still looked
  effectively `60hz-like` on the observed path

Interpretation:

- the public callback layer is not the only ceiling
- however blindly moving "lower" has not yet exposed a clean `120 Hz` producer path

### Virtual display classification

Useful durable conclusion:

- `SLVirtualDisplay` can provide HiDPI modes
- that does not automatically grant the override-backed physical-display classification that drives
  the friendlier macOS scaling UI

Interpretation:

- virtual-display UI classification remains a separate problem from encoded-capture cadence
- these two tracks should stay separate in future work

## Next Directions

Priority order:

1. `CaptureVideoToolboxProcessing`
   - first-submit cadence
   - first-IDR production timing
   - startup direct-vs-staged ordering
   - startup pacing that does not widen steady-state queue depth
2. startup-specific path specialization
   - reduce work before the first stable HEVC output
   - avoid broad queue changes that harm ProRes
3. better MDK-native startup diagnostics
   - first-submit timing
   - first-output timing
   - startup staged/direct counts
   - startup source-drop run length

## Update Rule

Keep this document concise.

When future experiments run:

1. use downstream `results.tsv` as the full experiment ledger
2. update this document only when a direction becomes:
   - a keep
   - a clear no-go class
   - a materially new bottleneck hypothesis
3. prefer grouped conclusions over per-experiment spam
