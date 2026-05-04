import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import MacDisplayKitObjCShim

enum MDKEncodedCaptureSourceBackend: String, Sendable {
    case privateDirectIOSurface = "private-direct-iosurface"
    case skyLightDisplayStream = "skylight-display-stream"
}

protocol MDKEncodedCaptureSourceRuntime: AnyObject, Sendable {
    var runtimeDescription: String { get }
    func start() throws
    func stop() -> Int32
}

struct MDKEncodedCaptureSourcePreparation: Sendable {
    let recommendedPendingFrameCount: Int
    let diagnosticNotes: [String]
    let skyLightTuningSelection: MDKSkyLightDisplayStreamAutotuningSelection?
}

protocol MDKEncodedCaptureProcessorRuntime: AnyObject, Sendable {
    func process(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws
    func requestImmediateKeyFrame()
    func finalize() -> MDKCaptureFrameProcessingSummary?
    func liveSummary() -> MDKCaptureFrameProcessingSummary?
}

extension MDKEncodedCaptureProcessorRuntime {
    func requestImmediateKeyFrame() {}
}

typealias MDKEncodedCaptureSourceFactory = @Sendable (
    MDKEncodedCaptureConfiguration,
    MDKEncodedCaptureSourcePreparation,
    @escaping @Sendable (MDKCaptureFrame) -> Void
) -> any MDKEncodedCaptureSourceRuntime

typealias MDKEncodedCaptureProcessorFactory = @Sendable (
    MDKEncodedCaptureConfiguration,
    @escaping @Sendable (MDKEncodedFrame) -> Void,
    @escaping @Sendable (String) -> Void
) -> any MDKEncodedCaptureProcessorRuntime

enum MDKSkyLightEncodedCaptureFrameAction: Equatable {
    case emitFresh
    case emitIdleReplay
    case drop
}

func MDKMachAbsoluteTicksForNanoseconds(_ nanoseconds: UInt64) -> UInt64 {
    guard nanoseconds > 0 else {
        return 0
    }

    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    guard timebase.numer != 0 else {
        return nanoseconds
    }

    let ticks = (Double(nanoseconds) * Double(timebase.denom)) / Double(timebase.numer)
    return UInt64(max(ticks.rounded(.up), 1))
}

func MDKResolveSkyLightEncodedCaptureFrameAction(
    status: CGDisplayStreamFrameStatus,
    hasFrameSurface: Bool,
    hasLastSurface: Bool,
    displayTime: UInt64,
    lastDisplayTime: UInt64?
) -> MDKSkyLightEncodedCaptureFrameAction {
    switch status {
    case .frameComplete:
        return hasFrameSurface ? .emitFresh : .drop
    case .frameIdle:
        guard hasLastSurface else {
            return .drop
        }
        guard let lastDisplayTime else {
            return .emitIdleReplay
        }
        return displayTime > lastDisplayTime ? .emitIdleReplay : .drop
    default:
        return .drop
    }
}

func MDKShouldEmitSyntheticSkyLightEncodedCaptureReplay(
    hasLastSurface: Bool,
    nextDisplayTime: UInt64,
    lastDisplayTime: UInt64?,
    currentMachTime: UInt64,
    lastEmissionMachTime: UInt64?,
    minimumEmissionDeltaMachTicks: UInt64
) -> Bool {
    guard hasLastSurface else {
        return false
    }

    if let lastDisplayTime, nextDisplayTime <= lastDisplayTime {
        return false
    }

    guard let lastEmissionMachTime else {
        return true
    }

    guard currentMachTime > lastEmissionMachTime else {
        return false
    }

    return (currentMachTime - lastEmissionMachTime) >= minimumEmissionDeltaMachTicks
}

func MDKResolvedSkyLightDisplayStreamShowCursor(
    requestedShowCursor: Bool,
    tuningSelection: MDKSkyLightDisplayStreamAutotuningSelection?
) -> Bool {
    _ = tuningSelection
    return requestedShowCursor
}

private actor MDKSkyLightEncodedCaptureReplayState {
    private var lastCaptureSurface: MDKCaptureSurface?
    private var lastDisplayTime: UInt64?
    private var lastEmissionMachTime: UInt64?

    func captureFrame(
        status: CGDisplayStreamFrameStatus,
        displayTime: UInt64,
        frameSurface: MDKCaptureSurface?,
        dirtyRects: [CGRect]?,
        sourceUpdateDropCount: UInt64?
    ) -> MDKCaptureFrame? {
        let action = MDKResolveSkyLightEncodedCaptureFrameAction(
            status: status,
            hasFrameSurface: frameSurface != nil,
            hasLastSurface: lastCaptureSurface != nil,
            displayTime: displayTime,
            lastDisplayTime: lastDisplayTime
        )

        switch action {
        case .emitFresh:
            guard let captureSurface = frameSurface else {
                return nil
            }
            lastCaptureSurface = captureSurface
            lastDisplayTime = displayTime
            lastEmissionMachTime = mach_absolute_time()
            return MDKCaptureFrame(
                sequenceNumber: displayTime,
                displayTime: displayTime,
                surfaceID: captureSurface.id,
                width: captureSurface.width,
                height: captureSurface.height,
                pixelFormat: captureSurface.pixelFormat,
                surface: captureSurface,
                origin: .fresh,
                dirtyRects: dirtyRects,
                sourceUpdateDropCount: sourceUpdateDropCount
            )
        case .emitIdleReplay:
            guard let lastCaptureSurface else {
                return nil
            }
            lastDisplayTime = displayTime
            lastEmissionMachTime = mach_absolute_time()
            return MDKCaptureFrame(
                sequenceNumber: displayTime,
                displayTime: displayTime,
                surfaceID: lastCaptureSurface.id,
                width: lastCaptureSurface.width,
                height: lastCaptureSurface.height,
                pixelFormat: lastCaptureSurface.pixelFormat,
                surface: lastCaptureSurface,
                origin: .idleReplay
            )
        case .drop:
            return nil
        }
    }

    func captureTimerReplay(
        displayTime: UInt64,
        minimumEmissionDeltaMachTicks: UInt64
    ) -> MDKCaptureFrame? {
        let currentMachTime = mach_absolute_time()
        guard MDKShouldEmitSyntheticSkyLightEncodedCaptureReplay(
            hasLastSurface: lastCaptureSurface != nil,
            nextDisplayTime: displayTime,
            lastDisplayTime: lastDisplayTime,
            currentMachTime: currentMachTime,
            lastEmissionMachTime: lastEmissionMachTime,
            minimumEmissionDeltaMachTicks: minimumEmissionDeltaMachTicks
        ) else {
            return nil
        }

        guard let lastCaptureSurface else {
            return nil
        }

        lastDisplayTime = displayTime
        lastEmissionMachTime = currentMachTime
        return MDKCaptureFrame(
            sequenceNumber: displayTime,
            displayTime: displayTime,
            surfaceID: lastCaptureSurface.id,
            width: lastCaptureSurface.width,
            height: lastCaptureSurface.height,
            pixelFormat: lastCaptureSurface.pixelFormat,
            surface: lastCaptureSurface,
            origin: .timerReplay
        )
    }
}

private final class MDKSkyLightEncodedCaptureSourceRuntime: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    private let shimSession: MDKShimSkyLightDisplayStreamSession
    private let tuningSelection: MDKSkyLightDisplayStreamAutotuningSelection?
    private let replayState: MDKSkyLightEncodedCaptureReplayState
    private let deliveryQueue: DispatchQueue
    private let frameHandler: @Sendable (MDKCaptureFrame) -> Void
    private let replayIntervalNanoseconds: UInt64
    private let replayIntervalMachTicks: UInt64
    private var replayTimer: DispatchSourceTimer?

    var runtimeDescription: String {
        guard let tuningSelection else {
            return MDKEncodedCaptureSourceBackend.skyLightDisplayStream.rawValue
        }

        return "\(MDKEncodedCaptureSourceBackend.skyLightDisplayStream.rawValue)[candidate=\(tuningSelection.candidate.identifier),queueDepth=\(tuningSelection.candidate.queueDepth),minimumFrameTime=\(String(format: "%.6f", tuningSelection.candidate.minimumFrameTime))]"
    }

    init(
        configuration: MDKEncodedCaptureConfiguration,
        tuningSelection: MDKSkyLightDisplayStreamAutotuningSelection?,
        frameHandler: @escaping @Sendable (MDKCaptureFrame) -> Void
    ) {
        let replayState = MDKSkyLightEncodedCaptureReplayState()
        let deliveryQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.encoded-capture.skylight.delivery")
        let replayIntervalNanoseconds = UInt64(
            max((1.0 / Double(max(configuration.targetFrameRate, 1))) * 1_000_000_000.0, 1_000_000.0)
        )
        self.tuningSelection = tuningSelection
        self.replayState = replayState
        self.deliveryQueue = deliveryQueue
        self.frameHandler = frameHandler
        self.replayIntervalNanoseconds = replayIntervalNanoseconds
        self.replayIntervalMachTicks = max(MDKMachAbsoluteTicksForNanoseconds(replayIntervalNanoseconds), 1)
        let tunedQueueDepth = tuningSelection?.candidate.queueDepth ?? configuration.streamConfiguration.resolvedQueueDepth
        let tunedMinimumFrameTime = tuningSelection?.candidate.minimumFrameTime ?? 0
        let tunedShowCursor = MDKResolvedSkyLightDisplayStreamShowCursor(
            requestedShowCursor: configuration.streamConfiguration.resolvedShowCursor,
            tuningSelection: tuningSelection
        )
        self.shimSession = MDKShimSkyLightDisplayStreamSession(
            displayID: UInt(configuration.displayID),
            minimumFrameTime: tunedMinimumFrameTime,
            queueDepth: tunedQueueDepth,
            showCursor: tunedShowCursor,
            outputWidth: UInt(configuration.streamConfiguration.resolvedOutputWidth),
            outputHeight: UInt(configuration.streamConfiguration.resolvedOutputHeight),
            pixelFormat: configuration.resolvedCapturePixelFormat,
            yCbCrMatrix: configuration.resolvedSkyLightDisplayStreamYCbCrMatrix.map { $0.imageBufferValue as String }
        ) { status, displayTime, frameSurface, reducedDirtyRectData, updateDropCount in
            let captureSurface = frameSurface.map(MDKCaptureSurface.init(ioSurface:))
            let dirtyRects = MDKDecodeCGRectData(reducedDirtyRectData)
            let sourceUpdateDropCount = UInt64(updateDropCount)
            deliveryQueue.async {
                Task {
                    guard let deliveredFrame = await replayState.captureFrame(
                        status: status,
                        displayTime: displayTime,
                        frameSurface: captureSurface,
                        dirtyRects: dirtyRects,
                        sourceUpdateDropCount: sourceUpdateDropCount
                    ) else {
                        return
                    }

                    frameHandler(deliveredFrame)
                }
            }
        }
    }

    func start() throws {
        try shimSession.start()
        let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        let intervalNanoseconds = min(replayIntervalNanoseconds, UInt64(Int.max))
        let leewayNanoseconds = min(max(intervalNanoseconds / 4, 500_000), UInt64(Int.max))
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNanoseconds)),
            repeating: .nanoseconds(Int(intervalNanoseconds)),
            leeway: .nanoseconds(Int(leewayNanoseconds))
        )
        let replayState = self.replayState
        let frameHandler = self.frameHandler
        let replayIntervalMachTicks = self.replayIntervalMachTicks
        timer.setEventHandler {
            let displayTime = mach_absolute_time()
            Task {
                guard let replayedFrame = await replayState.captureTimerReplay(
                    displayTime: displayTime,
                    minimumEmissionDeltaMachTicks: replayIntervalMachTicks
                ) else {
                    return
                }

                frameHandler(replayedFrame)
            }
        }
        replayTimer = timer
        timer.resume()
    }

    func stop() -> Int32 {
        replayTimer?.cancel()
        replayTimer = nil
        return shimSession.stop()
    }
}

private final class MDKCGDisplayStreamEncodedCaptureSourceRuntime: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    private let configuration: MDKEncodedCaptureConfiguration
    private let replayState: MDKSkyLightEncodedCaptureReplayState
    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let frameHandler: @Sendable (MDKCaptureFrame) -> Void
    private let replayIntervalNanoseconds: UInt64
    private let replayIntervalMachTicks: UInt64
    private var stream: CGDisplayStream?
    private var replayTimer: DispatchSourceTimer?

    var runtimeDescription: String {
        "cgdisplaystream-encoded-fallback"
    }

    init(
        configuration: MDKEncodedCaptureConfiguration,
        frameHandler: @escaping @Sendable (MDKCaptureFrame) -> Void
    ) {
        self.configuration = configuration
        self.replayState = MDKSkyLightEncodedCaptureReplayState()
        self.queue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.encoded-capture.cgdisplaystream.source"
        )
        self.deliveryQueue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.encoded-capture.cgdisplaystream.delivery"
        )
        self.frameHandler = frameHandler
        let replayIntervalNanoseconds = UInt64(
            max((1.0 / Double(max(configuration.targetFrameRate, 1))) * 1_000_000_000.0, 1_000_000.0)
        )
        self.replayIntervalNanoseconds = replayIntervalNanoseconds
        self.replayIntervalMachTicks = max(MDKMachAbsoluteTicksForNanoseconds(replayIntervalNanoseconds), 1)
    }

    func start() throws {
        guard stream == nil else {
            startReplayTimer()
            return
        }

        let captureConfiguration = MDKCaptureConfiguration(
            displayID: configuration.displayID,
            width: configuration.streamConfiguration.resolvedOutputWidth,
            height: configuration.streamConfiguration.resolvedOutputHeight,
            frameRate: configuration.targetFrameRate,
            pixelFormat: configuration.resolvedCapturePixelFormat,
            backend: .cgDisplayStream,
            dynamicRangeMode: configuration.resolvedEncodedHDRConfiguration == nil ? .sdr : .hdrLocal
        )
        let properties = MDKDisplayStreamProperties(
            for: captureConfiguration,
            logicalSize: MDKDisplayLogicalSize(displayID: CGDirectDisplayID(configuration.displayID))
        )
        let replayState = self.replayState
        let deliveryQueue = self.deliveryQueue
        let frameHandler = self.frameHandler
        let stream = CGDisplayStream(
            dispatchQueueDisplay: CGDirectDisplayID(configuration.displayID),
            outputWidth: max(configuration.streamConfiguration.resolvedOutputWidth, 1),
            outputHeight: max(configuration.streamConfiguration.resolvedOutputHeight, 1),
            pixelFormat: Int32(bitPattern: configuration.resolvedCapturePixelFormat),
            properties: properties,
            queue: queue
        ) { status, displayTime, surface, update in
            let captureSurface = surface.map(MDKCaptureSurface.init(ioSurface:))
            let sourceUpdateDropCount = update.map {
                UInt64($0.dropCount)
            }
            deliveryQueue.async {
                Task {
                    guard let deliveredFrame = await replayState.captureFrame(
                        status: status,
                        displayTime: displayTime,
                        frameSurface: captureSurface,
                        dirtyRects: nil,
                        sourceUpdateDropCount: sourceUpdateDropCount
                    ) else {
                        return
                    }
                    frameHandler(deliveredFrame)
                }
            }
        }

        guard let stream else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }
        let startError = stream.start()
        guard startError == .success else {
            throw MDKCaptureSessionError.streamStartFailed(
                displayID: configuration.displayID,
                errorCode: Int32(startError.rawValue)
            )
        }

        self.stream = stream
        startReplayTimer()
    }

    private func startReplayTimer() {
        guard replayTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        let intervalNanoseconds = min(replayIntervalNanoseconds, UInt64(Int.max))
        let leewayNanoseconds = min(max(intervalNanoseconds / 4, 500_000), UInt64(Int.max))
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNanoseconds)),
            repeating: .nanoseconds(Int(intervalNanoseconds)),
            leeway: .nanoseconds(Int(leewayNanoseconds))
        )
        let replayState = self.replayState
        let frameHandler = self.frameHandler
        let replayIntervalMachTicks = self.replayIntervalMachTicks
        timer.setEventHandler {
            let displayTime = mach_absolute_time()
            Task {
                guard let replayedFrame = await replayState.captureTimerReplay(
                    displayTime: displayTime,
                    minimumEmissionDeltaMachTicks: replayIntervalMachTicks
                ) else {
                    return
                }
                frameHandler(replayedFrame)
            }
        }
        replayTimer = timer
        timer.resume()
    }

    func stop() -> Int32 {
        replayTimer?.cancel()
        replayTimer = nil
        guard let stream else {
            return 0
        }
        self.stream = nil
        return Int32(stream.stop().rawValue)
    }
}

private final class MDKFallbackEncodedCaptureSourceRuntime: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    private let primary: any MDKEncodedCaptureSourceRuntime
    private let fallback: any MDKEncodedCaptureSourceRuntime
    private var activeSource: (any MDKEncodedCaptureSourceRuntime)?

    var runtimeDescription: String {
        if let activeSource {
            return activeSource.runtimeDescription
        }
        return "\(primary.runtimeDescription)->\(fallback.runtimeDescription)"
    }

    init(
        primary: any MDKEncodedCaptureSourceRuntime,
        fallback: any MDKEncodedCaptureSourceRuntime
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func start() throws {
        do {
            try primary.start()
            activeSource = primary
        } catch {
            try fallback.start()
            activeSource = fallback
        }
    }

    func stop() -> Int32 {
        guard let activeSource else {
            return 0
        }
        return activeSource.stop()
    }
}

private final class MDKPrivateDirectIOSurfaceEncodedCaptureSourceRuntime: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    private let shimSession: MDKShimPrivateDisplayIOSurfaceCaptureSession
    private let sourceBackend: MDKEncodedCaptureSourceBackend

    var runtimeDescription: String {
        sourceBackend.rawValue
    }

    init(
        configuration: MDKEncodedCaptureConfiguration,
        frameHandler: @escaping @Sendable (MDKCaptureFrame) -> Void
    ) {
        self.sourceBackend = configuration.resolvedSourceBackend
        let requestExtendedRange = configuration.resolvedEncodedHDRConfiguration.map {
            $0.transferFunction != .ituR709
        } ?? false
        self.shimSession = MDKShimPrivateDisplayIOSurfaceCaptureSession(
            displayID: UInt(configuration.displayID),
            targetFrameRate: configuration.targetFrameRate,
            requestExtendedRange: requestExtendedRange,
            useProxyCapture: false,
            showCursor: configuration.streamConfiguration.resolvedShowCursor,
            outputWidth: UInt(configuration.streamConfiguration.resolvedOutputWidth),
            outputHeight: UInt(configuration.streamConfiguration.resolvedOutputHeight),
            surfaceCount: configuration.resolvedPrivateCaptureSurfaceCount
        ) { status,
            displayTime,
            frameSurface,
            cursorSurface,
            cursorRectX,
            cursorRectY,
            cursorRectWidth,
            cursorRectHeight,
            cursorSurfaceIsVerticallyFlipped,
            captureDurationNanoseconds,
            cursorCompositeDurationNanoseconds in
            guard status == 0, let frameSurface else {
                return
            }

            let captureSurface = MDKCaptureSurface(ioSurface: frameSurface)
            let cursorOverlaySample = cursorSurface.flatMap { cursorSurface -> MDKCursorOverlaySample? in
                guard cursorRectWidth > 0, cursorRectHeight > 0 else {
                    return nil
                }
                let cursorSurface = MDKCaptureSurface(ioSurface: cursorSurface)
                return MDKCursorOverlaySample(
                    surface: cursorSurface,
                    rect: CGRect(
                        x: cursorRectX,
                        y: cursorRectY,
                        width: cursorRectWidth,
                        height: cursorRectHeight
                    ),
                    isVerticallyFlipped: cursorSurfaceIsVerticallyFlipped
                )
            }
            frameHandler(
                MDKCaptureFrame(
                    sequenceNumber: displayTime,
                    displayTime: displayTime,
                    surfaceID: captureSurface.id,
                    width: captureSurface.width,
                    height: captureSurface.height,
                    pixelFormat: captureSurface.pixelFormat,
                    surface: captureSurface,
                    origin: .fresh,
                    cursorOverlaySample: cursorOverlaySample,
                    sourceCaptureDurationNanoseconds: captureDurationNanoseconds,
                    sourceCursorCompositeDurationNanoseconds: cursorCompositeDurationNanoseconds
                )
            )
        }
    }

    func start() throws {
        try shimSession.start()
    }

    func stop() -> Int32 {
        shimSession.stop()
    }
}

// Safety: all mutable state is protected by `lock`, and callers only interact through
// value-free acquire/release operations that do not expose shared mutable storage.
private final class MDKEncodedCapturePendingFrameTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func tryAcquire(limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else {
            return false
        }
        count += 1
        return true
    }

    func releaseOne() {
        lock.lock()
        count = max(count - 1, 0)
        lock.unlock()
    }
}

private actor MDKEncodedCaptureLatestFrameMailbox {
    private var latestFrame: MDKCaptureFrame?

    func store(_ frame: MDKCaptureFrame) -> UInt64? {
        let replacedDisplayTime = latestFrame?.displayTime
        latestFrame = frame
        return replacedDisplayTime
    }

    func take() -> MDKCaptureFrame? {
        let frame = latestFrame
        latestFrame = nil
        return frame
    }
}

private func MDKProcessMailboxAwareSourceFrame(
    _ frame: MDKCaptureFrame,
    processor: any MDKEncodedCaptureProcessorRuntime,
    pendingFrameTracker: MDKEncodedCapturePendingFrameTracker,
    latestFrameMailbox: MDKEncodedCaptureLatestFrameMailbox,
    failureHandler: @escaping @Sendable (String) -> Void
) {
    do {
        try processor.process(frame: frame) {
            Task {
                if let latestFrame = await latestFrameMailbox.take() {
                    MDKProcessMailboxAwareSourceFrame(
                        latestFrame,
                        processor: processor,
                        pendingFrameTracker: pendingFrameTracker,
                        latestFrameMailbox: latestFrameMailbox,
                        failureHandler: failureHandler
                    )
                    return
                }

                pendingFrameTracker.releaseOne()
            }
        }
    } catch {
        pendingFrameTracker.releaseOne()
        let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        failureHandler(description)
    }
}

private final class MDKEncodedCaptureSourceCadenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount: UInt64 = 0
    private var displayDeltaCount: UInt64 = 0
    private var cumulativeDisplayDeltaMilliseconds: Double = 0
    private var previousDisplayTime: UInt64?
    private var lastDisplayDeltaMilliseconds: Double?
    private var minDisplayDeltaMilliseconds: Double?
    private var maxDisplayDeltaMilliseconds: Double?

    func record(displayTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        frameCount += 1
        if let previousDisplayTime, displayTime >= previousDisplayTime {
            let displayDeltaMilliseconds = Self.displayTimeDeltaMilliseconds(displayTime - previousDisplayTime)
            displayDeltaCount += 1
            cumulativeDisplayDeltaMilliseconds += displayDeltaMilliseconds
            lastDisplayDeltaMilliseconds = displayDeltaMilliseconds
            minDisplayDeltaMilliseconds = min(minDisplayDeltaMilliseconds ?? displayDeltaMilliseconds, displayDeltaMilliseconds)
            maxDisplayDeltaMilliseconds = max(maxDisplayDeltaMilliseconds ?? displayDeltaMilliseconds, displayDeltaMilliseconds)
        }
        previousDisplayTime = displayTime
    }

    func snapshotNotes() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard frameCount > 0 else {
            return []
        }

        var notes = [
            "sourceFrameCount=\(frameCount)",
            "sourceDisplayDeltaCount=\(displayDeltaCount)"
        ]

        if let lastDisplayDeltaMilliseconds {
            notes.append(String(format: "sourceLastDisplayDeltaMilliseconds=%.3f", lastDisplayDeltaMilliseconds))
        }
        if let minDisplayDeltaMilliseconds {
            notes.append(String(format: "sourceMinDisplayDeltaMilliseconds=%.3f", minDisplayDeltaMilliseconds))
        }
        if let maxDisplayDeltaMilliseconds {
            notes.append(String(format: "sourceMaxDisplayDeltaMilliseconds=%.3f", maxDisplayDeltaMilliseconds))
        }
        if displayDeltaCount > 0 {
            let averageDisplayDeltaMilliseconds = cumulativeDisplayDeltaMilliseconds / Double(displayDeltaCount)
            notes.append(String(format: "sourceAverageDisplayDeltaMilliseconds=%.3f", averageDisplayDeltaMilliseconds))
            let approximateFrameRate = averageDisplayDeltaMilliseconds > 0 ? (1000.0 / averageDisplayDeltaMilliseconds) : 0
            notes.append(String(format: "sourceApproxFrameRate=%.2f", approximateFrameRate))
            notes.append(
                "sourceCadenceClassification=\(Self.classifyCadence(forAverageDisplayDeltaMilliseconds: averageDisplayDeltaMilliseconds))"
            )
        }

        return notes
    }

    private static func displayTimeDeltaMilliseconds(_ delta: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else {
            return 0
        }

        let nanoseconds = (Double(delta) * Double(timebase.numer)) / Double(timebase.denom)
        return nanoseconds / 1_000_000
    }

    private static func classifyCadence(forAverageDisplayDeltaMilliseconds value: Double) -> String {
        switch value {
        case ..<12.0:
            return "120hz-like"
        case ..<20.0:
            return "60hz-like"
        case ..<29.0:
            return "40hz-like"
        case ..<37.0:
            return "30hz-like"
        default:
            return "sub-30hz"
        }
    }
}

private final class MDKEncodedCaptureSourceTimingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var captureSampleCount: UInt64 = 0
    private var cumulativeCaptureMilliseconds: Double = 0
    private var minCaptureMilliseconds: Double?
    private var maxCaptureMilliseconds: Double?
    private var cursorCompositeSampleCount: UInt64 = 0
    private var cumulativeCursorCompositeMilliseconds: Double = 0
    private var minCursorCompositeMilliseconds: Double?
    private var maxCursorCompositeMilliseconds: Double?
    private var reducedDirtySampleCount: UInt64 = 0
    private var reducedDirtyCoverageRatioSum: Double = 0
    private var reducedDirtyCoverageRatioMax: Double = 0
    private var reducedDirtyRectCountSum: UInt64 = 0
    private var reducedDirtyRectCountMax: UInt64 = 0
    private var updateDropSampleCount: UInt64 = 0
    private var updateDropCountSum: UInt64 = 0
    private var updateDropCountMax: UInt64 = 0

    func record(frame: MDKCaptureFrame) {
        lock.lock()
        defer { lock.unlock() }

        if let captureDurationNanoseconds = frame.sourceCaptureDurationNanoseconds {
            let captureMilliseconds = Double(captureDurationNanoseconds) / 1_000_000
            captureSampleCount += 1
            cumulativeCaptureMilliseconds += captureMilliseconds
            minCaptureMilliseconds = min(minCaptureMilliseconds ?? captureMilliseconds, captureMilliseconds)
            maxCaptureMilliseconds = max(maxCaptureMilliseconds ?? captureMilliseconds, captureMilliseconds)
        }

        if let cursorCompositeDurationNanoseconds = frame.sourceCursorCompositeDurationNanoseconds {
            let cursorCompositeMilliseconds = Double(cursorCompositeDurationNanoseconds) / 1_000_000
            guard cursorCompositeMilliseconds > 0 else {
                if let dirtyRects = frame.dirtyRects {
                    recordReducedDirtyStats(for: dirtyRects, frame: frame)
                }
                if let sourceUpdateDropCount = frame.sourceUpdateDropCount {
                    recordUpdateDropCount(sourceUpdateDropCount)
                }
                return
            }
            cursorCompositeSampleCount += 1
            cumulativeCursorCompositeMilliseconds += cursorCompositeMilliseconds
            minCursorCompositeMilliseconds = min(
                minCursorCompositeMilliseconds ?? cursorCompositeMilliseconds,
                cursorCompositeMilliseconds
            )
            maxCursorCompositeMilliseconds = max(
                maxCursorCompositeMilliseconds ?? cursorCompositeMilliseconds,
                cursorCompositeMilliseconds
            )
        }

        if let dirtyRects = frame.dirtyRects {
            recordReducedDirtyStats(for: dirtyRects, frame: frame)
        }
        if let sourceUpdateDropCount = frame.sourceUpdateDropCount {
            recordUpdateDropCount(sourceUpdateDropCount)
        }
    }

    func snapshotNotes() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var notes: [String] = []
        if captureSampleCount > 0 {
            notes.append("sourceCaptureSampleCount=\(captureSampleCount)")
            if let minCaptureMilliseconds {
                notes.append(String(format: "sourceMinCaptureMilliseconds=%.3f", minCaptureMilliseconds))
            }
            if let maxCaptureMilliseconds {
                notes.append(String(format: "sourceMaxCaptureMilliseconds=%.3f", maxCaptureMilliseconds))
            }
            notes.append(
                String(
                    format: "sourceAverageCaptureMilliseconds=%.3f",
                    cumulativeCaptureMilliseconds / Double(captureSampleCount)
                )
            )
        }

        if cursorCompositeSampleCount > 0 {
            notes.append("sourceCursorCompositeSampleCount=\(cursorCompositeSampleCount)")
            if let minCursorCompositeMilliseconds {
                notes.append(
                    String(format: "sourceMinCursorCompositeMilliseconds=%.3f", minCursorCompositeMilliseconds)
                )
            }
            if let maxCursorCompositeMilliseconds {
                notes.append(
                    String(format: "sourceMaxCursorCompositeMilliseconds=%.3f", maxCursorCompositeMilliseconds)
                )
            }
            notes.append(
                String(
                    format: "sourceAverageCursorCompositeMilliseconds=%.3f",
                    cumulativeCursorCompositeMilliseconds / Double(cursorCompositeSampleCount)
                )
            )
        }

        if reducedDirtySampleCount > 0 {
            notes.append("sourceReducedDirtySampleCount=\(reducedDirtySampleCount)")
            notes.append(
                String(
                    format: "sourceAverageReducedDirtyCoverageRatio=%.6f",
                    reducedDirtyCoverageRatioSum / Double(reducedDirtySampleCount)
                )
            )
            notes.append(
                String(format: "sourceMaxReducedDirtyCoverageRatio=%.6f", reducedDirtyCoverageRatioMax)
            )
            notes.append(
                String(
                    format: "sourceAverageReducedDirtyRectCount=%.3f",
                    Double(reducedDirtyRectCountSum) / Double(reducedDirtySampleCount)
                )
            )
            notes.append("sourceMaxReducedDirtyRectCount=\(reducedDirtyRectCountMax)")
        }

        if updateDropSampleCount > 0 {
            notes.append("sourceUpdateDropSampleCount=\(updateDropSampleCount)")
            notes.append(
                String(
                    format: "sourceAverageUpdateDropCount=%.3f",
                    Double(updateDropCountSum) / Double(updateDropSampleCount)
                )
            )
            notes.append("sourceMaxUpdateDropCount=\(updateDropCountMax)")
        }

        return notes
    }

    private func recordReducedDirtyStats(for dirtyRects: [CGRect], frame: MDKCaptureFrame) {
        guard frame.width > 0, frame.height > 0 else {
            return
        }

        let frameBounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let frameArea = frameBounds.width * frameBounds.height
        guard frameArea > 0 else {
            return
        }

        var coveredArea: CGFloat = 0
        for dirtyRect in dirtyRects {
            let clippedRect = dirtyRect.intersection(frameBounds)
            guard !clippedRect.isNull, !clippedRect.isEmpty else {
                continue
            }
            coveredArea += clippedRect.width * clippedRect.height
        }

        reducedDirtySampleCount += 1
        reducedDirtyCoverageRatioSum += min(Double(coveredArea / frameArea), 1.0)
        reducedDirtyCoverageRatioMax = max(reducedDirtyCoverageRatioMax, min(Double(coveredArea / frameArea), 1.0))
        reducedDirtyRectCountSum += UInt64(dirtyRects.count)
        reducedDirtyRectCountMax = max(reducedDirtyRectCountMax, UInt64(dirtyRects.count))
    }

    private func recordUpdateDropCount(_ dropCount: UInt64) {
        updateDropSampleCount += 1
        updateDropCountSum += dropCount
        updateDropCountMax = max(updateDropCountMax, dropCount)
    }
}

extension MDKVideoToolboxEncodingProcessor: MDKEncodedCaptureProcessorRuntime {}

public struct MDKEncodedCaptureSessionStatistics: Codable, Equatable, Sendable {
    public let emittedFrameCount: UInt64
    public let droppedFrameCount: UInt64
    public let processingFailureCount: UInt64
    public let automaticRestartCount: UInt64
    public let lastErrorDescription: String?
    public let lastStopStatus: Int32?
    public let isRunning: Bool
    public let minOutputCallbackLatencyMilliseconds: Double?
    public let maxOutputCallbackLatencyMilliseconds: Double?
    public let notes: [String]

    public init(
        emittedFrameCount: UInt64 = 0,
        droppedFrameCount: UInt64 = 0,
        processingFailureCount: UInt64 = 0,
        automaticRestartCount: UInt64 = 0,
        lastErrorDescription: String? = nil,
        lastStopStatus: Int32? = nil,
        isRunning: Bool = false,
        minOutputCallbackLatencyMilliseconds: Double? = nil,
        maxOutputCallbackLatencyMilliseconds: Double? = nil,
        notes: [String] = []
    ) {
        self.emittedFrameCount = emittedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.processingFailureCount = processingFailureCount
        self.automaticRestartCount = automaticRestartCount
        self.lastErrorDescription = lastErrorDescription
        self.lastStopStatus = lastStopStatus
        self.isRunning = isRunning
        self.minOutputCallbackLatencyMilliseconds = minOutputCallbackLatencyMilliseconds
        self.maxOutputCallbackLatencyMilliseconds = maxOutputCallbackLatencyMilliseconds
        self.notes = notes
    }
}

public enum MDKEncodedCaptureSessionEventKind: String, Codable, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
}

public struct MDKEncodedCaptureSessionEvent: Codable, Equatable, Sendable {
    public let kind: MDKEncodedCaptureSessionEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceDisplayTime: UInt64?

    public init(
        kind: MDKEncodedCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceDisplayTime: UInt64? = nil
    ) {
        self.kind = kind
        self.message = message
        self.stopStatus = stopStatus
        self.automaticRestartCount = automaticRestartCount
        self.sourceDisplayTime = sourceDisplayTime
    }
}

public struct MDKEncodedCaptureCallbacks: Sendable {
    public let frameHandler: @Sendable (MDKEncodedFrame) -> Void
    public let eventHandler: (@Sendable (MDKEncodedCaptureSessionEvent) -> Void)?

    public init(
        frameHandler: @escaping @Sendable (MDKEncodedFrame) -> Void,
        eventHandler: (@Sendable (MDKEncodedCaptureSessionEvent) -> Void)? = nil
    ) {
        self.frameHandler = frameHandler
        self.eventHandler = eventHandler
    }
}

public enum MDKEncodedCaptureSessionError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case callbackRequiredForCallbackOnlyMode
    case frameStreamUnsupportedInCallbackOnlyMode
    case processingFailed(description: String)
    case restartLimitReached(lastErrorDescription: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Encoded capture session is already running."
        case .callbackRequiredForCallbackOnlyMode:
            return "Encoded capture session requires callbacks when delivery mode is callback-only."
        case .frameStreamUnsupportedInCallbackOnlyMode:
            return "Encoded capture session does not support frame streams when delivery mode is callback-only."
        case .processingFailed(let description):
            return "Encoded capture session processing failed: \(description)"
        case .restartLimitReached(let lastErrorDescription):
            return "Encoded capture session exhausted its automatic restarts. Last error: \(lastErrorDescription)"
        }
    }
}

public actor MDKEncodedCaptureSession {
    public let configuration: MDKEncodedCaptureConfiguration

    private final class Runtime {
        let source: any MDKEncodedCaptureSourceRuntime
        let processor: any MDKEncodedCaptureProcessorRuntime

        init(
            source: any MDKEncodedCaptureSourceRuntime,
            processor: any MDKEncodedCaptureProcessorRuntime
        ) {
            self.source = source
            self.processor = processor
        }
    }

    private let sourceFactory: MDKEncodedCaptureSourceFactory
    private let processorFactory: MDKEncodedCaptureProcessorFactory

    private var runtime: Runtime?
    private var runtimeGeneration: UInt64 = 0
    private var streamToken: UInt64 = 0
    private var continuation: AsyncThrowingStream<MDKEncodedFrame, Error>.Continuation?
    private var continuationToken: UInt64?
    private var nextEventContinuationToken: UInt64 = 0
    private var eventContinuations: [UInt64: AsyncStream<MDKEncodedCaptureSessionEvent>.Continuation] = [:]
    private var callbacks: MDKEncodedCaptureCallbacks?
    private var statistics = MDKEncodedCaptureSessionStatistics()
    private var runtimeDiagnosticNotes: [String] = []
    private var sourceCadenceTracker: MDKEncodedCaptureSourceCadenceTracker?
    private var sourceTimingTracker: MDKEncodedCaptureSourceTimingTracker?
    private var scheduledRestartTask: Task<Void, Never>?
    private var scheduledRestartGeneration: UInt64?

    public init(configuration: MDKEncodedCaptureConfiguration) {
        self.configuration = configuration
        self.sourceFactory = { configuration, preparation, frameHandler in
            switch configuration.resolvedSourceBackend {
            case .privateDirectIOSurface:
                return MDKPrivateDirectIOSurfaceEncodedCaptureSourceRuntime(
                    configuration: configuration,
                    frameHandler: frameHandler
                )
            case .skyLightDisplayStream:
                let primary = MDKSkyLightEncodedCaptureSourceRuntime(
                    configuration: configuration,
                    tuningSelection: preparation.skyLightTuningSelection,
                    frameHandler: frameHandler
                )
                let fallback = MDKCGDisplayStreamEncodedCaptureSourceRuntime(
                    configuration: configuration,
                    frameHandler: frameHandler
                )
                return MDKFallbackEncodedCaptureSourceRuntime(
                    primary: primary,
                    fallback: fallback
                )
            }
        }
        self.processorFactory = { configuration, outputHandler, failureHandler in
            return MDKVideoToolboxEncodingProcessor(
                codec: configuration.codec,
                preprocessStrategy: configuration.preprocessStrategy,
                targetFrameRate: configuration.targetFrameRate,
                encoderInputStrategy: configuration.resolvedEncoderInputStrategy,
                maxInflightStagingSlots: 128,
                outputHandler: outputHandler,
                failureHandler: failureHandler,
                hdrConfiguration: configuration.resolvedEncodedHDRConfiguration,
                targetAverageBitRateBitsPerSecond: configuration.targetAverageBitRateBitsPerSecond,
                tileMetadata: configuration.tileLayout.metadata(frameGroupID: 0)
            )
        }
    }

    init(
        configuration: MDKEncodedCaptureConfiguration,
        sourceFactory: @escaping MDKEncodedCaptureSourceFactory,
        processorFactory: @escaping MDKEncodedCaptureProcessorFactory
    ) {
        self.configuration = configuration
        self.sourceFactory = sourceFactory
        self.processorFactory = processorFactory
    }

    private static func makeSourcePreparation(
        for configuration: MDKEncodedCaptureConfiguration
    ) async -> MDKEncodedCaptureSourcePreparation {
        switch configuration.resolvedSourceBackend {
        case .privateDirectIOSurface:
            let requestsExtendedRange = configuration.resolvedEncodedHDRConfiguration.map {
                $0.transferFunction != .ituR709
            } ?? false
            let cursorComposition = configuration.streamConfiguration.resolvedShowCursor
                ? "metal-overlay-on-encode"
                : "disabled"
            let sourceColorTransform =
                requestsExtendedRange ? "negotiated-source-primaries-to-hdr-signal" : "negotiated-source-primaries"
            return MDKEncodedCaptureSourcePreparation(
                recommendedPendingFrameCount: max(configuration.resolvedPrivateCaptureSurfaceCount - 1, 1),
                diagnosticNotes: [
                    "sourceBackend=\(MDKEncodedCaptureSourceBackend.privateDirectIOSurface.rawValue)",
                    String(format: "privateCaptureSourcePixelFormat=0x%08X", kCVPixelFormatType_32BGRA),
                    String(format: "privateCaptureRequestedPixelFormat=0x%08X", configuration.resolvedCapturePixelFormat),
                    "privateCaptureExtendedRange=\(requestsExtendedRange)",
                    "privateCaptureCursorComposition=\(cursorComposition)",
                    "privateCaptureSourceColorTransform=\(sourceColorTransform)"
                ],
                skyLightTuningSelection: nil
            )
        case .skyLightDisplayStream:
            let tuningSelection = await MDKSkyLightDisplayStreamAutotuner.shared.resolveSelection(for: configuration)
            let queueDepth = tuningSelection?.candidate.queueDepth ?? configuration.streamConfiguration.resolvedQueueDepth
            let recommendedPendingFrameCount = recommendedSkyLightPendingFrameCount(
                for: configuration,
                queueDepth: queueDepth
            )
            let pendingPolicy =
                configuration.deliveryMode == .callbackOnly &&
                configuration.resolvedSkyLightProcessingMode != nil
                ? "callback-low-latency"
                : "default"
            return MDKEncodedCaptureSourcePreparation(
                recommendedPendingFrameCount: recommendedPendingFrameCount,
                diagnosticNotes: (tuningSelection?.notes ?? []) + [
                    "sourceBackend=\(MDKEncodedCaptureSourceBackend.skyLightDisplayStream.rawValue)",
                    "rawPrivateDisplayStream=true",
                    String(format: "rawPrivateDisplayStreamRequestedPixelFormat=0x%08X", configuration.resolvedCapturePixelFormat),
                    "rawPrivateDisplayStreamRequestedMatrix=\(configuration.resolvedSkyLightDisplayStreamYCbCrMatrix?.imageBufferValue as String? ?? "unset")",
                    "skyLightSyntheticIdleReplay=true",
                    String(
                        format: "skyLightSyntheticIdleReplayIntervalMilliseconds=%.3f",
                        1000.0 / Double(max(configuration.targetFrameRate, 1))
                    ),
                    "skyLightPendingPolicy=\(pendingPolicy)",
                    "skyLightRecommendedPendingFrameCount=\(recommendedPendingFrameCount)"
                ],
                skyLightTuningSelection: tuningSelection
            )
        }
    }

    static func recommendedSkyLightPendingFrameCount(
        for configuration: MDKEncodedCaptureConfiguration,
        queueDepth: Int
    ) -> Int {
        let effectiveQueueDepth = max(queueDepth, 1)
        let usesLowLatencyCallbackEncode =
            configuration.deliveryMode == .callbackOnly &&
            configuration.resolvedSkyLightProcessingMode != nil

        if usesLowLatencyCallbackEncode {
            return 16
        }

        return min(max(effectiveQueueDepth * 3, 10), 16)
    }

    public func frames() -> AsyncThrowingStream<MDKEncodedFrame, Error> {
        makeFrameStream()
    }

    public func events() -> AsyncStream<MDKEncodedCaptureSessionEvent> {
        makeEventStream()
    }

    public func makeFrameStream() -> AsyncThrowingStream<MDKEncodedFrame, Error> {
        if configuration.deliveryMode == .callbackOnly {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MDKEncodedCaptureSessionError.frameStreamUnsupportedInCallbackOnlyMode
                )
            }
        }

        streamToken += 1
        let token = streamToken
        let box = MDKEncodedCaptureContinuationBox()
        let bufferingPolicy = configuration.backpressurePolicy.streamBufferingPolicy
        let stream = AsyncThrowingStream<MDKEncodedFrame, Error>(bufferingPolicy: bufferingPolicy) { continuation in
            box.continuation = continuation
        }

        guard let continuation = box.continuation else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.clearContinuation(ifMatching: token)
            }
        }

        installContinuation(continuation, token: token)
        return stream
    }

    public func makeEventStream() -> AsyncStream<MDKEncodedCaptureSessionEvent> {
        nextEventContinuationToken += 1
        let token = nextEventContinuationToken
        let box = MDKEncodedCaptureEventContinuationBox()
        let stream = AsyncStream<MDKEncodedCaptureSessionEvent> { continuation in
            box.continuation = continuation
        }

        guard let continuation = box.continuation else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        continuation.onTermination = { [weak self] (_: AsyncStream<MDKEncodedCaptureSessionEvent>.Continuation.Termination) in
            guard let self else {
                return
            }
            Task {
                await self.removeEventContinuation(token: token)
            }
        }

        eventContinuations[token] = continuation
        return stream
    }

    public func start() async throws {
        try await start(callbacks: callbacks)
    }

    public func start(callbacks: MDKEncodedCaptureCallbacks) async throws {
        try await start(callbacks: Optional(callbacks))
    }

    public func installCallbacks(_ callbacks: MDKEncodedCaptureCallbacks?) {
        self.callbacks = callbacks
    }

    private func start(callbacks: MDKEncodedCaptureCallbacks?) async throws {
        guard runtime == nil else {
            throw MDKEncodedCaptureSessionError.alreadyRunning
        }
        if configuration.deliveryMode == .callbackOnly, callbacks == nil {
            throw MDKEncodedCaptureSessionError.callbackRequiredForCallbackOnlyMode
        }

        self.callbacks = callbacks
        runtimeGeneration &+= 1
        let currentRuntimeGeneration = runtimeGeneration
        let callbackOnlyDelivery = configuration.deliveryMode == .callbackOnly && callbacks != nil
        let shouldRecordSourceDiagnostics = !(
            configuration.codec == .hevc &&
            callbackOnlyDelivery &&
            configuration.resolvedSkyLightProcessingMode != nil
        )
        let pendingFrameTracker = MDKEncodedCapturePendingFrameTracker()
        let latestFrameMailbox = MDKEncodedCaptureLatestFrameMailbox()
        let sourceCadenceTracker = shouldRecordSourceDiagnostics ? MDKEncodedCaptureSourceCadenceTracker() : nil
        let sourceTimingTracker = shouldRecordSourceDiagnostics ? MDKEncodedCaptureSourceTimingTracker() : nil
        let sourcePreparation = await Self.makeSourcePreparation(for: configuration)
        let maximumPendingFrameCount = sourcePreparation.recommendedPendingFrameCount

        let outputHandler: @Sendable (MDKEncodedFrame) -> Void = { [weak self] encodedFrame in
            guard let self else {
                return
            }
            callbacks?.frameHandler(encodedFrame)
            if callbackOnlyDelivery {
                return
            }
            Task {
                await self.handleEncodedFrame(
                    encodedFrame,
                    runtimeGeneration: currentRuntimeGeneration,
                    deliveredViaCallback: callbacks != nil
                )
            }
        }
        let failureHandler: @Sendable (String) -> Void = { [weak self] description in
            guard let self else {
                return
            }
            Task {
                await self.handleProcessingFailure(description, runtimeGeneration: currentRuntimeGeneration)
            }
        }

        let processor = processorFactory(configuration, outputHandler, failureHandler)
        let source = sourceFactory(configuration, sourcePreparation) { [weak self, weak processor] frame in
            guard let self, let processor else {
                return
            }

            sourceCadenceTracker?.record(displayTime: frame.displayTime)
            sourceTimingTracker?.record(frame: frame)
            guard pendingFrameTracker.tryAcquire(limit: maximumPendingFrameCount) else {
                Task {
                    let replacedDisplayTime = await latestFrameMailbox.store(frame)
                    if let replacedDisplayTime {
                        await self.handleSourceFrameDropped(
                            sourceDisplayTime: replacedDisplayTime,
                            runtimeGeneration: currentRuntimeGeneration
                        )
                    }
                }
                return
            }

            MDKProcessMailboxAwareSourceFrame(
                frame,
                processor: processor,
                pendingFrameTracker: pendingFrameTracker,
                latestFrameMailbox: latestFrameMailbox,
                failureHandler: failureHandler
            )
        }
        self.sourceCadenceTracker = sourceCadenceTracker
        self.sourceTimingTracker = sourceTimingTracker
        runtimeDiagnosticNotes = sourcePreparation.diagnosticNotes
        if !shouldRecordSourceDiagnostics {
            runtimeDiagnosticNotes.append("sourceHotPathDiagnostics=disabled")
        }

        do {
            try source.start()
        } catch {
            self.sourceCadenceTracker = nil
            self.sourceTimingTracker = nil
            statistics = preservedStatistics(
                lastErrorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                isRunning: false
            )
            throw error
        }

        runtime = Runtime(source: source, processor: processor)
        statistics = preservedStatistics(
            lastStopStatus: nil,
            isRunning: true,
            notes: mergedRuntimeNotes(with: statistics.notes)
        )
        let startupDiagnostics = statistics.notes.joined(separator: ";")
        emitEvent(
            .init(
                kind: .started,
                message: startupDiagnostics.isEmpty
                    ? "Encoded capture session started using \(source.runtimeDescription)."
                    : "Encoded capture session started using \(source.runtimeDescription). \(startupDiagnostics)"
            )
        )
    }

    public func stop() async {
        stopRuntime(finishingStream: true, stopMessage: "Encoded capture session stopped.")
        await drainDeferredDeliveryWork()
    }

    public func restart() async throws {
        stopRuntime(finishingStream: false, emitStopEvent: false)
        try await start()
    }

    public func statisticsSnapshot() -> MDKEncodedCaptureSessionStatistics {
        guard configuration.deliveryMode == .callbackOnly,
              let runtime,
              let summary = runtime.processor.liveSummary() else {
            return statistics
        }

        return mergedStatistics(
            with: summary,
            isRunning: statistics.isRunning,
            sourceNotes: combinedSourceNotes()
        )
    }

    public func requestImmediateKeyFrame() {
        runtime?.processor.requestImmediateKeyFrame()
    }

    private func installContinuation(
        _ continuation: AsyncThrowingStream<MDKEncodedFrame, Error>.Continuation,
        token: UInt64
    ) {
        self.continuation?.finish()
        self.continuation = continuation
        self.continuationToken = token
    }

    private func clearContinuation(ifMatching token: UInt64) {
        guard continuationToken == token else {
            return
        }
        continuation = nil
        continuationToken = nil
        if runtime != nil, callbacks == nil {
            stopRuntime(finishingStream: false, stopMessage: "Encoded frame consumer terminated.")
        }
    }

    private func handleEncodedFrame(
        _ frame: MDKEncodedFrame,
        runtimeGeneration: UInt64,
        deliveredViaCallback: Bool
    ) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }
        var deliveredFrame = deliveredViaCallback
        guard let continuation else {
            if deliveredViaCallback {
                statistics = preservedStatistics(
                    emittedFrameCount: statistics.emittedFrameCount + 1
                )
            } else {
                statistics = preservedStatistics(
                    droppedFrameCount: statistics.droppedFrameCount + 1
                )
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Encoded frame dropped because no active consumer stream exists.",
                        sourceDisplayTime: frame.sourceDisplayTime
                    )
                )
            }
            return
        }

        switch continuation.yield(frame) {
        case .enqueued:
            deliveredFrame = true
            statistics = preservedStatistics(
                emittedFrameCount: statistics.emittedFrameCount + (deliveredViaCallback ? 0 : 1)
            )
        case .dropped:
            if deliveredViaCallback {
                statistics = preservedStatistics(
                    emittedFrameCount: statistics.emittedFrameCount + 1
                )
            } else {
                statistics = preservedStatistics(
                    droppedFrameCount: statistics.droppedFrameCount + 1
                )
            }
            if !deliveredViaCallback {
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Encoded frame dropped by backpressure policy.",
                        sourceDisplayTime: frame.sourceDisplayTime
                    )
                )
            }
        case .terminated:
            self.continuation = nil
            self.continuationToken = nil
            statistics = preservedStatistics(
                emittedFrameCount: statistics.emittedFrameCount + (deliveredViaCallback ? 1 : 0),
                droppedFrameCount: statistics.droppedFrameCount + (deliveredViaCallback ? 0 : 1)
            )
            if !deliveredViaCallback {
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Encoded frame stream terminated while a frame was being delivered.",
                        sourceDisplayTime: frame.sourceDisplayTime
                    )
                )
            }
            if runtime != nil, !deliveredViaCallback {
                stopRuntime(
                    finishingStream: false,
                    stopMessage: "Encoded frame consumer terminated during delivery."
                )
            }
        @unknown default:
            break
        }

        if deliveredViaCallback && !deliveredFrame {
            statistics = preservedStatistics(
                emittedFrameCount: statistics.emittedFrameCount + 1
            )
        }
    }

    private func handleProcessingFailure(_ description: String, runtimeGeneration: UInt64) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }
        statistics = preservedStatistics(
            processingFailureCount: statistics.processingFailureCount + 1,
            lastErrorDescription: description
        )
        emitEvent(.init(kind: .failed, message: description))

        guard scheduledRestartTask == nil else {
            return
        }
        guard configuration.recoveryPolicy.automaticallyRestartOnFailure else {
            stopRuntime(finishingStream: false, stopMessage: description)
            continuation?.finish(
                throwing: MDKEncodedCaptureSessionError.processingFailed(description: description)
            )
            continuation = nil
            continuationToken = nil
            return
        }
        guard statistics.automaticRestartCount < UInt64(configuration.recoveryPolicy.maximumAutomaticRestartCount) else {
            stopRuntime(finishingStream: false, stopMessage: description)
            continuation?.finish(
                throwing: MDKEncodedCaptureSessionError.restartLimitReached(lastErrorDescription: description)
            )
            continuation = nil
            continuationToken = nil
            return
        }

        scheduledRestartGeneration = runtimeGeneration
        scheduledRestartTask = Task { [weak self] in
            guard let self else {
                return
            }
            let delayNanoseconds = UInt64(configuration.recoveryPolicy.restartDelay * 1_000_000_000)
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await self.performScheduledRestart(
                lastErrorDescription: description,
                restartGeneration: runtimeGeneration
            )
        }
    }

    private func handleSourceFrameDropped(sourceDisplayTime: UInt64, runtimeGeneration: UInt64) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }

        statistics = preservedStatistics(
            droppedFrameCount: statistics.droppedFrameCount + 1
        )
        emitEvent(
            .init(
                kind: .droppedFrame,
                message: "Source frame dropped before processing because the capture processing queue is saturated.",
                sourceDisplayTime: sourceDisplayTime
            )
        )
    }

    private func performScheduledRestart(lastErrorDescription: String, restartGeneration: UInt64) async {
        guard runtime != nil,
              self.runtimeGeneration == restartGeneration,
              scheduledRestartGeneration == restartGeneration else {
            scheduledRestartTask = nil
            scheduledRestartGeneration = nil
            return
        }
        scheduledRestartTask = nil
        scheduledRestartGeneration = nil

        stopRuntime(finishingStream: false, emitStopEvent: false)
        do {
            try await start()
            statistics = preservedStatistics(
                automaticRestartCount: statistics.automaticRestartCount + 1,
                lastErrorDescription: lastErrorDescription,
                isRunning: true
            )
            emitEvent(
                .init(
                    kind: .restarted,
                    message: lastErrorDescription,
                    automaticRestartCount: statistics.automaticRestartCount
                )
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            continuation?.finish(
                throwing: MDKEncodedCaptureSessionError.restartLimitReached(lastErrorDescription: message)
            )
            continuation = nil
            continuationToken = nil
            emitEvent(.init(kind: .failed, message: message))
        }
    }

    private func stopRuntime(
        finishingStream: Bool,
        stopMessage: String? = nil,
        emitStopEvent: Bool = true
    ) {
        runtimeGeneration &+= 1
        scheduledRestartTask?.cancel()
        scheduledRestartTask = nil
        scheduledRestartGeneration = nil

        guard let runtime else {
            sourceCadenceTracker = nil
            sourceTimingTracker = nil
            if finishingStream {
                continuation?.finish()
                continuation = nil
                continuationToken = nil
            }
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: false
            )
            if emitStopEvent {
                emitEvent(
                    .init(
                        kind: .stopped,
                        message: stopMessage ?? (finishingStream ? "Encoded capture session stopped." : "Encoded capture runtime stopped."),
                        stopStatus: statistics.lastStopStatus
                    )
                )
            }
            if finishingStream {
                callbacks = nil
            }
            return
        }

        let stopStatus = runtime.source.stop()
        let processingSummary = runtime.processor.finalize()
        let sourceNotes = combinedSourceNotes()
        self.runtime = nil
        if finishingStream {
            continuation?.finish()
            continuation = nil
            continuationToken = nil
        }
        let finalizedEmittedFrameCount: UInt64
        if callbacks != nil, let completedOutputFrameCount = processingSummary?.completedOutputFrameCount {
            finalizedEmittedFrameCount = max(statistics.emittedFrameCount, completedOutputFrameCount)
        } else {
            finalizedEmittedFrameCount = statistics.emittedFrameCount
        }
        statistics = MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: finalizedEmittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            processingFailureCount: max(
                statistics.processingFailureCount,
                processingSummary?.processingFailureCount ?? 0
            ),
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: stopStatus,
            isRunning: false,
            minOutputCallbackLatencyMilliseconds: processingSummary?.minOutputCallbackLatencyMilliseconds,
            maxOutputCallbackLatencyMilliseconds: processingSummary?.maxOutputCallbackLatencyMilliseconds,
            notes: mergedRuntimeNotes(with: (processingSummary?.notes ?? statistics.notes) + sourceNotes)
        )
        sourceCadenceTracker = nil
        sourceTimingTracker = nil
        if emitStopEvent {
            emitEvent(
                .init(
                    kind: .stopped,
                    message: stopMessage ?? (finishingStream ? "Encoded capture session stopped." : "Encoded capture runtime stopped."),
                    stopStatus: stopStatus
                )
            )
        }
        if finishingStream {
            callbacks = nil
        }
    }

    private func mergedStatistics(
        with summary: MDKCaptureFrameProcessingSummary,
        isRunning: Bool,
        sourceNotes: [String] = []
    ) -> MDKEncodedCaptureSessionStatistics {
        MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: max(statistics.emittedFrameCount, summary.completedOutputFrameCount ?? 0),
            droppedFrameCount: statistics.droppedFrameCount,
            processingFailureCount: max(statistics.processingFailureCount, summary.processingFailureCount),
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: statistics.lastStopStatus,
            isRunning: isRunning,
            minOutputCallbackLatencyMilliseconds: summary.minOutputCallbackLatencyMilliseconds,
            maxOutputCallbackLatencyMilliseconds: summary.maxOutputCallbackLatencyMilliseconds,
            notes: mergedRuntimeNotes(with: summary.notes + sourceNotes)
        )
    }

    private func preservedStatistics(
        emittedFrameCount: UInt64? = nil,
        droppedFrameCount: UInt64? = nil,
        processingFailureCount: UInt64? = nil,
        automaticRestartCount: UInt64? = nil,
        lastErrorDescription: String? = nil,
        lastStopStatus: Int32?? = nil,
        isRunning: Bool? = nil,
        notes: [String]? = nil
    ) -> MDKEncodedCaptureSessionStatistics {
        MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: emittedFrameCount ?? statistics.emittedFrameCount,
            droppedFrameCount: droppedFrameCount ?? statistics.droppedFrameCount,
            processingFailureCount: processingFailureCount ?? statistics.processingFailureCount,
            automaticRestartCount: automaticRestartCount ?? statistics.automaticRestartCount,
            lastErrorDescription: lastErrorDescription ?? statistics.lastErrorDescription,
            lastStopStatus: lastStopStatus ?? statistics.lastStopStatus,
            isRunning: isRunning ?? statistics.isRunning,
            minOutputCallbackLatencyMilliseconds: statistics.minOutputCallbackLatencyMilliseconds,
            maxOutputCallbackLatencyMilliseconds: statistics.maxOutputCallbackLatencyMilliseconds,
            notes: notes ?? statistics.notes
        )
    }

    private func mergedRuntimeNotes(with notes: [String]) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []

        for note in runtimeDiagnosticNotes + notes {
            guard seen.insert(note).inserted else {
                continue
            }
            merged.append(note)
        }

        return merged
    }

    private func combinedSourceNotes() -> [String] {
        (sourceCadenceTracker?.snapshotNotes() ?? []) + (sourceTimingTracker?.snapshotNotes() ?? [])
    }

    private func emitEvent(_ event: MDKEncodedCaptureSessionEvent) {
        callbacks?.eventHandler?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(token: UInt64) {
        eventContinuations[token] = nil
    }

    private func drainDeferredDeliveryWork() async {
        for _ in 0..<3 {
            await Task.yield()
        }
    }
}

private final class MDKEncodedCaptureContinuationBox {
    var continuation: AsyncThrowingStream<MDKEncodedFrame, Error>.Continuation?
}

private final class MDKEncodedCaptureEventContinuationBox {
    var continuation: AsyncStream<MDKEncodedCaptureSessionEvent>.Continuation?
}
