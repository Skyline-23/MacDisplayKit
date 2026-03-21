import Foundation

@objcMembers
public final class MDKCaptureBenchmarkResult: NSObject {
    public let backend: MDKCaptureBackend
    public let processingMode: MDKCaptureBenchmarkProcessingMode
    public let requestedFrameRate: Int
    public let requestedSampleDuration: TimeInterval
    public let measuredDuration: TimeInterval
    public let callbackCount: UInt64
    public let deliveredFrameCount: UInt64
    public let skippedFrameCount: UInt64
    public let observedFrameRate: Double
    public let deliveryRatio: Double
    public let firstFrameLatency: TimeInterval?
    public let processedFrameCount: UInt64
    public let processingFailureCount: UInt64
    public let processedFrameRate: Double
    public let processedFrameRatio: Double
    public let deliveredFrameWidth: Int?
    public let deliveredFrameHeight: Int?
    public let deliveredPixelFormat: UInt32?
    public let deliveredFrameMatchesRequest: Bool?

    public init(
        backend: MDKCaptureBackend,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        requestedFrameRate: Int,
        requestedSampleDuration: TimeInterval,
        measuredDuration: TimeInterval,
        callbackCount: UInt64,
        deliveredFrameCount: UInt64,
        skippedFrameCount: UInt64,
        observedFrameRate: Double,
        deliveryRatio: Double,
        firstFrameLatency: TimeInterval?,
        processedFrameCount: UInt64,
        processingFailureCount: UInt64,
        processedFrameRate: Double,
        processedFrameRatio: Double,
        deliveredFrameWidth: Int?,
        deliveredFrameHeight: Int?,
        deliveredPixelFormat: UInt32?,
        deliveredFrameMatchesRequest: Bool?
    ) {
        self.backend = backend
        self.processingMode = processingMode
        self.requestedFrameRate = requestedFrameRate
        self.requestedSampleDuration = requestedSampleDuration
        self.measuredDuration = measuredDuration
        self.callbackCount = callbackCount
        self.deliveredFrameCount = deliveredFrameCount
        self.skippedFrameCount = skippedFrameCount
        self.observedFrameRate = observedFrameRate
        self.deliveryRatio = deliveryRatio
        self.firstFrameLatency = firstFrameLatency
        self.processedFrameCount = processedFrameCount
        self.processingFailureCount = processingFailureCount
        self.processedFrameRate = processedFrameRate
        self.processedFrameRatio = processedFrameRatio
        self.deliveredFrameWidth = deliveredFrameWidth
        self.deliveredFrameHeight = deliveredFrameHeight
        self.deliveredPixelFormat = deliveredPixelFormat
        self.deliveredFrameMatchesRequest = deliveredFrameMatchesRequest
        super.init()
    }
}

struct MDKCaptureBenchmarkTimeline {
    var firstFrameTime: TimeInterval?
    var lastFrameTime: TimeInterval?

    mutating func recordFrame(at time: TimeInterval) {
        if firstFrameTime == nil {
            firstFrameTime = time
        }
        lastFrameTime = time
    }
}

struct MDKCaptureBenchmarkProcessingSnapshot {
    let processedFrameCount: UInt64
    let processingFailureCount: UInt64
}

struct MDKCaptureBenchmarkFrameSnapshot {
    let width: Int?
    let height: Int?
    let pixelFormat: UInt32?
}

private struct MDKCaptureBenchmarkRecordingSnapshot {
    let timeline: MDKCaptureBenchmarkTimeline
    let processing: MDKCaptureBenchmarkProcessingSnapshot
    let deliveredFrame: MDKCaptureBenchmarkFrameSnapshot
}

private actor MDKCaptureBenchmarkRecorder {
    private var timeline = MDKCaptureBenchmarkTimeline()
    private var processedFrameCount: UInt64 = 0
    private var processingFailureCount: UInt64 = 0
    private var deliveredFrameWidth: Int?
    private var deliveredFrameHeight: Int?
    private var deliveredFramePixelFormat: UInt32?
    private var isRecording = false

    func beginRecording() {
        timeline = MDKCaptureBenchmarkTimeline()
        processedFrameCount = 0
        processingFailureCount = 0
        deliveredFrameWidth = nil
        deliveredFrameHeight = nil
        deliveredFramePixelFormat = nil
        isRecording = true
    }

    func recordFrame(
        at time: TimeInterval,
        width: Int,
        height: Int,
        pixelFormat: UInt32,
        processingSucceeded: Bool
    ) {
        guard isRecording else {
            return
        }

        timeline.recordFrame(at: time)

        if deliveredFrameWidth == nil {
            deliveredFrameWidth = width
            deliveredFrameHeight = height
            deliveredFramePixelFormat = pixelFormat
        }

        if processingSucceeded {
            processedFrameCount += 1
        } else {
            processingFailureCount += 1
        }
    }

    func finishRecording() -> MDKCaptureBenchmarkRecordingSnapshot {
        isRecording = false
        return MDKCaptureBenchmarkRecordingSnapshot(
            timeline: timeline,
            processing: MDKCaptureBenchmarkProcessingSnapshot(
                processedFrameCount: processedFrameCount,
                processingFailureCount: processingFailureCount
            ),
            deliveredFrame: MDKCaptureBenchmarkFrameSnapshot(
                width: deliveredFrameWidth,
                height: deliveredFrameHeight,
                pixelFormat: deliveredFramePixelFormat
            )
        )
    }
}

private final class MDKCaptureBenchmarkBridgeBox<T>: @unchecked Sendable {
    var result: T?
}

private enum MDKCaptureBenchmarkActorBridge {
    static func wait<T>(
        _ operation: @escaping @Sendable () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = MDKCaptureBenchmarkBridgeBox<T>()

        Task { [box] in
            box.result = await operation()
            semaphore.signal()
        }

        semaphore.wait()
        return box.result!
    }
}

enum MDKCaptureBenchmarkAnalyzer {
    static func result(
        configuration: MDKCaptureConfiguration,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        stats: MDKCaptureSessionStatistics,
        processing: MDKCaptureBenchmarkProcessingSnapshot,
        deliveredFrame: MDKCaptureBenchmarkFrameSnapshot,
        sampleDuration: TimeInterval,
        measuredDuration: TimeInterval,
        timeline: MDKCaptureBenchmarkTimeline,
        runStartedAt: TimeInterval
    ) -> MDKCaptureBenchmarkResult {
        let effectiveDuration: TimeInterval
        if let firstFrameTime = timeline.firstFrameTime,
           let lastFrameTime = timeline.lastFrameTime,
           lastFrameTime > firstFrameTime {
            effectiveDuration = lastFrameTime - firstFrameTime
        } else {
            effectiveDuration = max(measuredDuration, sampleDuration, 0)
        }

        let observedFrameRate: Double
        if stats.deliveredFrameCount > 1, effectiveDuration > 0 {
            observedFrameRate = Double(stats.deliveredFrameCount - 1) / effectiveDuration
        } else {
            observedFrameRate = 0
        }

        let targetFrameRate = max(configuration.frameRate, 1)
        let deliveryRatio = min(observedFrameRate / Double(targetFrameRate), 1.0)

        let firstFrameLatency = timeline.firstFrameTime.map { max($0 - runStartedAt, 0) }

        let processedFrameRate: Double
        let processedFrameRatio: Double
        if effectiveDuration > 0 {
            processedFrameRate = Double(processing.processedFrameCount) / effectiveDuration
            if stats.deliveredFrameCount > 0 {
                processedFrameRatio = Double(processing.processedFrameCount) / Double(stats.deliveredFrameCount)
            } else {
                processedFrameRatio = 0
            }
        } else {
            processedFrameRate = 0
            processedFrameRatio = 0
        }

        let deliveredFrameMatchesRequest = deliveredFrame.width.map { width in
            width == configuration.width &&
            deliveredFrame.height == configuration.height &&
            deliveredFrame.pixelFormat == configuration.pixelFormat
        }

        return MDKCaptureBenchmarkResult(
            backend: configuration.backend,
            processingMode: processingMode,
            requestedFrameRate: configuration.frameRate,
            requestedSampleDuration: sampleDuration,
            measuredDuration: measuredDuration,
            callbackCount: stats.callbackCount,
            deliveredFrameCount: stats.deliveredFrameCount,
            skippedFrameCount: stats.skippedFrameCount,
            observedFrameRate: observedFrameRate,
            deliveryRatio: deliveryRatio,
            firstFrameLatency: firstFrameLatency,
            processedFrameCount: processing.processedFrameCount,
            processingFailureCount: processing.processingFailureCount,
            processedFrameRate: processedFrameRate,
            processedFrameRatio: processedFrameRatio,
            deliveredFrameWidth: deliveredFrame.width,
            deliveredFrameHeight: deliveredFrame.height,
            deliveredPixelFormat: deliveredFrame.pixelFormat,
            deliveredFrameMatchesRequest: deliveredFrameMatchesRequest
        )
    }
}

protocol MDKCaptureSessionControlling: AnyObject {
    var backend: MDKCaptureBackend { get }
    var isRunning: Bool { get }
    var statistics: MDKCaptureSessionStatistics { get }
    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws
    func stop()
}

extension MDKCaptureSession: MDKCaptureSessionControlling {}

public enum MDKCaptureBenchmarkRunner {
    public static func run(
        configuration: MDKCaptureConfiguration,
        processingMode: MDKCaptureBenchmarkProcessingMode = .metalCopy,
        warmupDuration: TimeInterval = 1.0,
        sampleDuration: TimeInterval = 1.0
    ) throws -> MDKCaptureBenchmarkResult {
        try run(
            configuration: configuration,
            processingMode: processingMode,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration,
            makeSession: MDKCaptureSessionFactory.makeSession(configuration:),
            makeProcessor: { try MDKCaptureFrameProcessingFactory.make(processingMode: processingMode) },
            timeSource: { ProcessInfo.processInfo.systemUptime },
            sleeper: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func run(
        configuration: MDKCaptureConfiguration,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        warmupDuration: TimeInterval,
        sampleDuration: TimeInterval,
        makeSession: (MDKCaptureConfiguration) throws -> MDKCaptureSessionControlling,
        makeProcessor: () throws -> any MDKCaptureFrameProcessing,
        timeSource: @escaping @Sendable () -> TimeInterval,
        sleeper: (TimeInterval) -> Void
    ) throws -> MDKCaptureBenchmarkResult {
        let clampedWarmupDuration = max(warmupDuration, 0)
        let clampedSampleDuration = max(sampleDuration, 0)
        let session = try makeSession(configuration)
        let recorder = MDKCaptureBenchmarkRecorder()
        let processor = try makeProcessor()

        try session.start { frame in
            let processingSucceeded: Bool
            do {
                try processor.process(frame: frame)
                processingSucceeded = true
            } catch {
                processingSucceeded = false
            }

            let frameWidth = frame.width
            let frameHeight = frame.height
            let framePixelFormat = frame.pixelFormat
            let frameTime = timeSource()
            MDKCaptureBenchmarkActorBridge.wait {
                await recorder.recordFrame(
                    at: frameTime,
                    width: frameWidth,
                    height: frameHeight,
                    pixelFormat: framePixelFormat,
                    processingSucceeded: processingSucceeded
                )
            }
        }

        if clampedWarmupDuration > 0 {
            sleeper(clampedWarmupDuration)
        }

        let baselineStats = session.statistics
        MDKCaptureBenchmarkActorBridge.wait {
            await recorder.beginRecording()
        }
        let measurementStartedAt = timeSource()
        sleeper(clampedSampleDuration)
        session.stop()
        let measuredStats = session.statistics.delta(since: baselineStats)
        let recording = MDKCaptureBenchmarkActorBridge.wait {
            await recorder.finishRecording()
        }

        let measuredDuration = max(timeSource() - measurementStartedAt, 0)
        return MDKCaptureBenchmarkAnalyzer.result(
            configuration: configuration,
            processingMode: processingMode,
            stats: measuredStats,
            processing: recording.processing,
            deliveredFrame: recording.deliveredFrame,
            sampleDuration: clampedSampleDuration,
            measuredDuration: measuredDuration,
            timeline: recording.timeline,
            runStartedAt: measurementStartedAt
        )
    }
}
