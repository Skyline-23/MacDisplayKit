import Foundation

@objcMembers
public final class MDKCaptureBenchmarkResult: NSObject {
    public let backend: MDKCaptureBackend
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

    public init(
        backend: MDKCaptureBackend,
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
        processedFrameRatio: Double
    ) {
        self.backend = backend
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

private final class MDKCaptureBenchmarkTimelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timeline = MDKCaptureBenchmarkTimeline()
    private let timeSource: @Sendable () -> TimeInterval
    private var isRecording = false

    init(timeSource: @escaping @Sendable () -> TimeInterval) {
        self.timeSource = timeSource
    }

    func recordFrame() {
        lock.lock()
        if isRecording {
            timeline.recordFrame(at: timeSource())
        }
        lock.unlock()
    }

    func beginRecording() {
        lock.lock()
        timeline = MDKCaptureBenchmarkTimeline()
        isRecording = true
        lock.unlock()
    }

    func endRecording() -> MDKCaptureBenchmarkTimeline {
        lock.lock()
        isRecording = false
        let capturedTimeline = timeline
        lock.unlock()
        return capturedTimeline
    }

    func snapshot() -> MDKCaptureBenchmarkTimeline {
        lock.lock()
        let capturedTimeline = timeline
        lock.unlock()
        return capturedTimeline
    }
}

struct MDKCaptureBenchmarkProcessingSnapshot {
    let processedFrameCount: UInt64
    let processingFailureCount: UInt64
}

private final class MDKCaptureBenchmarkProcessingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var processedFrameCount: UInt64 = 0
    private var processingFailureCount: UInt64 = 0
    private var isRecording = false

    func recordSuccess() {
        lock.lock()
        if isRecording {
            processedFrameCount += 1
        }
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        if isRecording {
            processingFailureCount += 1
        }
        lock.unlock()
    }

    func beginRecording() {
        lock.lock()
        processedFrameCount = 0
        processingFailureCount = 0
        isRecording = true
        lock.unlock()
    }

    func endRecording() -> MDKCaptureBenchmarkProcessingSnapshot {
        lock.lock()
        isRecording = false
        let snapshot = MDKCaptureBenchmarkProcessingSnapshot(
            processedFrameCount: processedFrameCount,
            processingFailureCount: processingFailureCount
        )
        lock.unlock()
        return snapshot
    }

    func snapshot() -> MDKCaptureBenchmarkProcessingSnapshot {
        lock.lock()
        let snapshot = MDKCaptureBenchmarkProcessingSnapshot(
            processedFrameCount: processedFrameCount,
            processingFailureCount: processingFailureCount
        )
        lock.unlock()
        return snapshot
    }
}

enum MDKCaptureBenchmarkAnalyzer {
    static func result(
        configuration: MDKCaptureConfiguration,
        stats: MDKCaptureSessionStatistics,
        processing: MDKCaptureBenchmarkProcessingSnapshot,
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

        return MDKCaptureBenchmarkResult(
            backend: configuration.backend,
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
            processedFrameRatio: processedFrameRatio
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
        warmupDuration: TimeInterval = 1.0,
        sampleDuration: TimeInterval = 1.0
    ) throws -> MDKCaptureBenchmarkResult {
        try run(
            configuration: configuration,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration,
            makeSession: MDKCaptureSessionFactory.makeSession(configuration:),
            makeProcessor: { try MDKMetalTextureBindingProcessor() },
            timeSource: { ProcessInfo.processInfo.systemUptime },
            sleeper: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func run(
        configuration: MDKCaptureConfiguration,
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
        let timeline = MDKCaptureBenchmarkTimelineBox(timeSource: timeSource)
        let processing = MDKCaptureBenchmarkProcessingBox()
        let processor = try makeProcessor()

        try session.start { frame in
            timeline.recordFrame()
            do {
                try processor.process(frame: frame)
                processing.recordSuccess()
            } catch {
                processing.recordFailure()
            }
        }

        if clampedWarmupDuration > 0 {
            sleeper(clampedWarmupDuration)
        }

        let measurementStartedAt = timeSource()
        let baselineStats = session.statistics
        timeline.beginRecording()
        processing.beginRecording()
        sleeper(clampedSampleDuration)
        let measuredTimeline = timeline.endRecording()
        let measuredProcessing = processing.endRecording()
        let measuredStats = session.statistics.delta(since: baselineStats)
        session.stop()

        let measuredDuration = max(timeSource() - measurementStartedAt, 0)
        return MDKCaptureBenchmarkAnalyzer.result(
            configuration: configuration,
            stats: measuredStats,
            processing: measuredProcessing,
            sampleDuration: clampedSampleDuration,
            measuredDuration: measuredDuration,
            timeline: measuredTimeline,
            runStartedAt: measurementStartedAt
        )
    }
}
