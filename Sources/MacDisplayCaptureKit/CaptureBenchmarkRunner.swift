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
        firstFrameLatency: TimeInterval?
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

    init(timeSource: @escaping @Sendable () -> TimeInterval) {
        self.timeSource = timeSource
    }

    func recordFrame() {
        lock.lock()
        timeline.recordFrame(at: timeSource())
        lock.unlock()
    }

    func snapshot() -> MDKCaptureBenchmarkTimeline {
        lock.lock()
        let capturedTimeline = timeline
        lock.unlock()
        return capturedTimeline
    }
}

enum MDKCaptureBenchmarkAnalyzer {
    static func result(
        configuration: MDKCaptureConfiguration,
        stats: MDKCaptureSessionStatistics,
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
            firstFrameLatency: firstFrameLatency
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
        sampleDuration: TimeInterval = 1.0
    ) throws -> MDKCaptureBenchmarkResult {
        try run(
            configuration: configuration,
            sampleDuration: sampleDuration,
            makeSession: MDKCaptureSessionFactory.makeSession(configuration:),
            timeSource: { ProcessInfo.processInfo.systemUptime },
            sleeper: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func run(
        configuration: MDKCaptureConfiguration,
        sampleDuration: TimeInterval,
        makeSession: (MDKCaptureConfiguration) throws -> MDKCaptureSessionControlling,
        timeSource: @escaping @Sendable () -> TimeInterval,
        sleeper: (TimeInterval) -> Void
    ) throws -> MDKCaptureBenchmarkResult {
        let clampedSampleDuration = max(sampleDuration, 0)
        let session = try makeSession(configuration)
        let runStartedAt = timeSource()
        let timeline = MDKCaptureBenchmarkTimelineBox(timeSource: timeSource)

        try session.start { _ in
            timeline.recordFrame()
        }

        sleeper(clampedSampleDuration)
        session.stop()

        let measuredDuration = max(timeSource() - runStartedAt, 0)
        return MDKCaptureBenchmarkAnalyzer.result(
            configuration: configuration,
            stats: session.statistics,
            sampleDuration: clampedSampleDuration,
            measuredDuration: measuredDuration,
            timeline: timeline.snapshot(),
            runStartedAt: runStartedAt
        )
    }
}
