import XCTest
@testable import MacDisplayCaptureKit

final class MacDisplayCaptureBenchmarkRunnerTests: XCTestCase {
    func testAnalyzerUsesDeliveredFramesToComputeObservedFrameRate() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 3840,
            height: 2160,
            frameRate: 120,
            pixelFormat: 0x78343230,
            backend: .cgDisplayStream,
            dynamicRangeMode: .hdrCanonical
        )
        let stats = MDKCaptureSessionStatistics(
            callbackCount: 132,
            deliveredFrameCount: 120,
            skippedFrameCount: 12,
            lastDisplayTime: 99
        )
        var timeline = MDKCaptureBenchmarkTimeline()
        timeline.recordFrame(at: 10.1)
        timeline.recordFrame(at: 11.0916666667)

        let result = MDKCaptureBenchmarkAnalyzer.result(
            configuration: configuration,
            stats: stats,
            sampleDuration: 1.0,
            measuredDuration: 1.2,
            timeline: timeline,
            runStartedAt: 10.0
        )

        XCTAssertEqual(result.backend, .cgDisplayStream)
        XCTAssertEqual(result.callbackCount, 132)
        XCTAssertEqual(result.deliveredFrameCount, 120)
        XCTAssertEqual(result.skippedFrameCount, 12)
        XCTAssertEqual(result.observedFrameRate, 120.0, accuracy: 0.05)
        XCTAssertEqual(result.deliveryRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.firstFrameLatency ?? -1, 0.1, accuracy: 0.0001)
    }

    func testAnalyzerFallsBackToMeasuredDurationWithoutFrameTimeline() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 2560,
            height: 1440,
            frameRate: 120,
            pixelFormat: 0x78343230,
            backend: .cgDisplayStream,
            dynamicRangeMode: .hdrCanonical
        )
        let stats = MDKCaptureSessionStatistics(
            callbackCount: 24,
            deliveredFrameCount: 1,
            skippedFrameCount: 23,
            lastDisplayTime: 0
        )

        let result = MDKCaptureBenchmarkAnalyzer.result(
            configuration: configuration,
            stats: stats,
            sampleDuration: 1.0,
            measuredDuration: 1.5,
            timeline: MDKCaptureBenchmarkTimeline(),
            runStartedAt: 3.0
        )

        XCTAssertEqual(result.observedFrameRate, 0)
        XCTAssertEqual(result.deliveryRatio, 0)
        XCTAssertNil(result.firstFrameLatency)
    }

    func testRunnerCollectsFramesFromSessionAndReturnsBenchmarkResult() throws {
        let configuration = MDKCaptureConfiguration(
            displayID: 99,
            width: 3840,
            height: 2160,
            frameRate: 120,
            pixelFormat: 0x78343230,
            backend: .cgDisplayStream,
            dynamicRangeMode: .hdrCanonical
        )
        let session = FakeCaptureSession(backend: .cgDisplayStream)
        let timeBox = FakeTimeBox(initial: 20.0)

        let result = try MDKCaptureBenchmarkRunner.run(
            configuration: configuration,
            sampleDuration: 1.0,
            makeSession: { _ in session },
            timeSource: { timeBox.currentTime },
            sleeper: { duration in
                timeBox.advance(by: 0.05)
                session.emitFrame()
                timeBox.advance(by: 0.05)
                session.emitFrame()
                timeBox.advance(by: 0.05)
                session.emitSkippedCallback()
                timeBox.advance(by: max(duration - 0.15, 0))
            }
        )

        XCTAssertEqual(result.backend, .cgDisplayStream)
        XCTAssertEqual(result.deliveredFrameCount, 2)
        XCTAssertEqual(result.skippedFrameCount, 1)
        XCTAssertEqual(result.callbackCount, 3)
        XCTAssertEqual(result.observedFrameRate, 20.0, accuracy: 0.001)
        XCTAssertEqual(result.deliveryRatio, 20.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(result.firstFrameLatency ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertFalse(session.isRunning)
    }
}

private final class FakeCaptureSession: MDKCaptureSessionControlling {
    let backend: MDKCaptureBackend
    private(set) var isRunning = false
    private(set) var statistics = MDKCaptureSessionStatistics.zero
    private var frameHandler: MDKCaptureFrameHandler?
    private var nextSequence: UInt64 = 0

    init(backend: MDKCaptureBackend) {
        self.backend = backend
    }

    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws {
        guard !isRunning else {
            throw MDKCaptureSessionError.alreadyRunning
        }
        isRunning = true
        self.frameHandler = frameHandler
    }

    func stop() {
        isRunning = false
        frameHandler = nil
    }

    func emitFrame() {
        statistics = MDKCaptureSessionStatistics(
            callbackCount: statistics.callbackCount + 1,
            deliveredFrameCount: statistics.deliveredFrameCount + 1,
            skippedFrameCount: statistics.skippedFrameCount,
            lastDisplayTime: statistics.lastDisplayTime + 1
        )
        nextSequence += 1
        frameHandler?(
            MDKCaptureFrame(
                sequenceNumber: nextSequence,
                displayTime: statistics.lastDisplayTime,
                surfaceID: UInt32(nextSequence),
                width: 3840,
                height: 2160,
                pixelFormat: 0x78343230
            )
        )
    }

    func emitSkippedCallback() {
        statistics = MDKCaptureSessionStatistics(
            callbackCount: statistics.callbackCount + 1,
            deliveredFrameCount: statistics.deliveredFrameCount,
            skippedFrameCount: statistics.skippedFrameCount + 1,
            lastDisplayTime: statistics.lastDisplayTime + 1
        )
    }
}

private final class FakeTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(initial: TimeInterval) {
        self.time = initial
    }

    var currentTime: TimeInterval {
        lock.lock()
        let snapshot = time
        lock.unlock()
        return snapshot
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        time += delta
        lock.unlock()
    }
}
