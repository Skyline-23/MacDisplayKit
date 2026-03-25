import CoreVideo
import Foundation
import MacDisplayKitObjCShim

enum MDKEncodedCaptureSourceBackend: String, Sendable {
    case privateDirectIOSurface = "private-direct-iosurface"
    case privateProxyIOSurface = "private-proxy-iosurface"
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
    func finalize() -> MDKCaptureFrameProcessingSummary?
    func liveSummary() -> MDKCaptureFrameProcessingSummary?
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

private final class MDKSkyLightEncodedCaptureSourceRuntime: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    private let shimSession: MDKShimSkyLightDisplayStreamSession
    private let tuningSelection: MDKSkyLightDisplayStreamAutotuningSelection?

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
        self.tuningSelection = tuningSelection
        let tunedQueueDepth = tuningSelection?.candidate.queueDepth ?? configuration.streamConfiguration.resolvedQueueDepth
        let tunedMinimumFrameTime = tuningSelection?.candidate.minimumFrameTime ?? 0
        let tunedShowCursor = tuningSelection?.candidate.showCursor ?? configuration.streamConfiguration.resolvedShowCursor
        self.shimSession = MDKShimSkyLightDisplayStreamSession(
            displayID: UInt(configuration.displayID),
            minimumFrameTime: tunedMinimumFrameTime,
            queueDepth: tunedQueueDepth,
            showCursor: tunedShowCursor,
            outputWidth: UInt(configuration.streamConfiguration.resolvedOutputWidth),
            outputHeight: UInt(configuration.streamConfiguration.resolvedOutputHeight),
            pixelFormat: configuration.resolvedCapturePixelFormat,
            yCbCrMatrix: configuration.resolvedSkyLightDisplayStreamYCbCrMatrix.map { $0.imageBufferValue as String }
        ) { status, displayTime, frameSurface in
            guard status == .frameComplete, let frameSurface else {
                return
            }

            let captureSurface = MDKCaptureSurface(ioSurface: frameSurface)
            frameHandler(
                MDKCaptureFrame(
                    sequenceNumber: displayTime,
                    displayTime: displayTime,
                    surfaceID: captureSurface.id,
                    width: captureSurface.width,
                    height: captureSurface.height,
                    pixelFormat: captureSurface.pixelFormat,
                    surface: captureSurface
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
            useProxyCapture: sourceBackend == .privateProxyIOSurface,
            showCursor: configuration.streamConfiguration.resolvedShowCursor,
            outputWidth: UInt(configuration.streamConfiguration.resolvedOutputWidth),
            outputHeight: UInt(configuration.streamConfiguration.resolvedOutputHeight),
            surfaceCount: configuration.resolvedPrivateCaptureSurfaceCount
        ) { status, displayTime, frameSurface in
            guard status == 0, let frameSurface else {
                return
            }

            let captureSurface = MDKCaptureSurface(ioSurface: frameSurface)
            frameHandler(
                MDKCaptureFrame(
                    sequenceNumber: displayTime,
                    displayTime: displayTime,
                    surfaceID: captureSurface.id,
                    width: captureSurface.width,
                    height: captureSurface.height,
                    pixelFormat: captureSurface.pixelFormat,
                    surface: captureSurface
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
    private var scheduledRestartTask: Task<Void, Never>?
    private var scheduledRestartGeneration: UInt64?

    public init(configuration: MDKEncodedCaptureConfiguration) {
        self.configuration = configuration
        self.sourceFactory = { configuration, preparation, frameHandler in
            switch configuration.resolvedSourceBackend {
            case .privateProxyIOSurface, .privateDirectIOSurface:
                return MDKPrivateDirectIOSurfaceEncodedCaptureSourceRuntime(
                    configuration: configuration,
                    frameHandler: frameHandler
                )
            case .skyLightDisplayStream:
                return MDKSkyLightEncodedCaptureSourceRuntime(
                    configuration: configuration,
                    tuningSelection: preparation.skyLightTuningSelection,
                    frameHandler: frameHandler
                )
            }
        }
        self.processorFactory = { configuration, outputHandler, failureHandler in
            MDKVideoToolboxEncodingProcessor(
                codec: configuration.codec,
                preprocessStrategy: configuration.preprocessStrategy,
                targetFrameRate: configuration.targetFrameRate,
                encoderInputStrategy: configuration.resolvedEncoderInputStrategy,
                outputHandler: outputHandler,
                failureHandler: failureHandler,
                hdrConfiguration: configuration.resolvedEncodedHDRConfiguration
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
        case .privateDirectIOSurface, .privateProxyIOSurface:
            return MDKEncodedCaptureSourcePreparation(
                recommendedPendingFrameCount: max(configuration.resolvedPrivateCaptureSurfaceCount - 1, 1),
                diagnosticNotes: [],
                skyLightTuningSelection: nil
            )
        case .skyLightDisplayStream:
            let tuningSelection = await MDKSkyLightDisplayStreamAutotuner.shared.resolveSelection(for: configuration)
            return MDKEncodedCaptureSourcePreparation(
                recommendedPendingFrameCount: max(
                    tuningSelection?.candidate.queueDepth ?? configuration.streamConfiguration.resolvedQueueDepth,
                    1
                ),
                diagnosticNotes: tuningSelection?.notes ?? [],
                skyLightTuningSelection: tuningSelection
            )
        }
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
        let processingQueue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.encoded-capture.processing",
            qos: .userInteractive,
            attributes: .concurrent
        )
        let pendingFrameTracker = MDKEncodedCapturePendingFrameTracker()
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

            guard pendingFrameTracker.tryAcquire(limit: maximumPendingFrameCount) else {
                Task {
                    await self.handleSourceFrameDropped(
                        sourceDisplayTime: frame.displayTime,
                        runtimeGeneration: currentRuntimeGeneration
                    )
                }
                return
            }

            processingQueue.async {
                do {
                    try processor.process(frame: frame) {
                        pendingFrameTracker.releaseOne()
                    }
                } catch {
                    pendingFrameTracker.releaseOne()
                    let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    Task {
                        await self.handleProcessingFailure(description, runtimeGeneration: currentRuntimeGeneration)
                    }
                }
            }
        }
        runtimeDiagnosticNotes = sourcePreparation.diagnosticNotes

        do {
            try source.start()
        } catch {
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                lastStopStatus: statistics.lastStopStatus,
                isRunning: false
            )
            throw error
        }

        runtime = Runtime(source: source, processor: processor)
        statistics = MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: nil,
                isRunning: true,
                notes: mergedRuntimeNotes(with: statistics.notes)
            )
        emitEvent(
            .init(
                kind: .started,
                message: "Encoded capture session started using \(source.runtimeDescription)."
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

        return mergedStatistics(with: summary, isRunning: statistics.isRunning)
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
                statistics = MDKEncodedCaptureSessionStatistics(
                    emittedFrameCount: statistics.emittedFrameCount + 1,
                    droppedFrameCount: statistics.droppedFrameCount,
                    processingFailureCount: statistics.processingFailureCount,
                    automaticRestartCount: statistics.automaticRestartCount,
                    lastErrorDescription: statistics.lastErrorDescription,
                    lastStopStatus: statistics.lastStopStatus,
                    isRunning: statistics.isRunning
                )
            } else {
                statistics = MDKEncodedCaptureSessionStatistics(
                    emittedFrameCount: statistics.emittedFrameCount,
                    droppedFrameCount: statistics.droppedFrameCount + 1,
                    processingFailureCount: statistics.processingFailureCount,
                    automaticRestartCount: statistics.automaticRestartCount,
                    lastErrorDescription: statistics.lastErrorDescription,
                    lastStopStatus: statistics.lastStopStatus,
                    isRunning: statistics.isRunning
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
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount + (deliveredViaCallback ? 0 : 1),
                droppedFrameCount: statistics.droppedFrameCount,
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: statistics.isRunning
            )
        case .dropped:
            if deliveredViaCallback {
                statistics = MDKEncodedCaptureSessionStatistics(
                    emittedFrameCount: statistics.emittedFrameCount + 1,
                    droppedFrameCount: statistics.droppedFrameCount,
                    processingFailureCount: statistics.processingFailureCount,
                    automaticRestartCount: statistics.automaticRestartCount,
                    lastErrorDescription: statistics.lastErrorDescription,
                    lastStopStatus: statistics.lastStopStatus,
                    isRunning: statistics.isRunning
                )
            } else {
                statistics = MDKEncodedCaptureSessionStatistics(
                    emittedFrameCount: statistics.emittedFrameCount,
                    droppedFrameCount: statistics.droppedFrameCount + 1,
                    processingFailureCount: statistics.processingFailureCount,
                    automaticRestartCount: statistics.automaticRestartCount,
                    lastErrorDescription: statistics.lastErrorDescription,
                    lastStopStatus: statistics.lastStopStatus,
                    isRunning: statistics.isRunning
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
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount + (deliveredViaCallback ? 1 : 0),
                droppedFrameCount: statistics.droppedFrameCount + (deliveredViaCallback ? 0 : 1),
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: statistics.isRunning
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
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount + 1,
                droppedFrameCount: statistics.droppedFrameCount,
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: statistics.isRunning
            )
        }
    }

    private func handleProcessingFailure(_ description: String, runtimeGeneration: UInt64) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }
        statistics = MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            processingFailureCount: statistics.processingFailureCount + 1,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: description,
            lastStopStatus: statistics.lastStopStatus,
            isRunning: statistics.isRunning
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

        statistics = MDKEncodedCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount + 1,
            processingFailureCount: statistics.processingFailureCount,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: statistics.lastStopStatus,
            isRunning: statistics.isRunning
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
            statistics = MDKEncodedCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                processingFailureCount: statistics.processingFailureCount,
                automaticRestartCount: statistics.automaticRestartCount + 1,
                lastErrorDescription: lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
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
            notes: mergedRuntimeNotes(with: processingSummary?.notes ?? statistics.notes)
        )
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
        isRunning: Bool
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
            notes: mergedRuntimeNotes(with: summary.notes)
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
