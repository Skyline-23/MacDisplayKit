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

    func testSuiteRunnerCollectsAvailableCandidatesAndSkipsUnavailableOnes() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let plan = MDKCaptureBenchmarkPlan(
            target: target,
            display: display,
            intent: .compareBackends,
            candidates: [
                MDKCaptureBackendCandidate(
                    backend: .cgDisplayStream,
                    available: true,
                    reason: "Primary backend available."
                ),
                MDKCaptureBackendCandidate(
                    backend: .avFoundation,
                    available: false,
                    reason: "Fallback unavailable."
                ),
            ]
        )

        let suite = MDKCaptureBenchmarkSuiteRunner.run(
            plan: plan,
            pixelFormat: 0x78343230,
            sampleDuration: 1.0,
            runBenchmark: { configuration, sampleDuration in
                XCTAssertEqual(configuration.backend, .cgDisplayStream)
                XCTAssertEqual(sampleDuration, 1.0, accuracy: 0.0001)
                return MDKCaptureBenchmarkResult(
                    backend: configuration.backend,
                    requestedFrameRate: configuration.frameRate,
                    requestedSampleDuration: sampleDuration,
                    measuredDuration: 1.05,
                    callbackCount: 120,
                    deliveredFrameCount: 118,
                    skippedFrameCount: 2,
                    observedFrameRate: 117.7,
                    deliveryRatio: 117.7 / 120.0,
                    firstFrameLatency: 0.02
                )
            }
        )

        XCTAssertEqual(suite.measurements.count, 2)
        XCTAssertEqual(suite.successfulMeasurements.count, 1)
        XCTAssertEqual(suite.measurements[0].backend, .cgDisplayStream)
        XCTAssertNotNil(suite.measurements[0].result)
        XCTAssertNil(suite.measurements[0].errorDescription)
        XCTAssertEqual(suite.measurements[1].backend, .avFoundation)
        XCTAssertNil(suite.measurements[1].result)
        XCTAssertFalse(suite.measurements[1].available)
    }

    func testJudgePassesMeasurementThatMeetsTargetThresholds() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let measurement = MDKCaptureBenchmarkMeasurement(
            backend: .cgDisplayStream,
            available: true,
            reason: "Primary backend available.",
            result: MDKCaptureBenchmarkResult(
                backend: .cgDisplayStream,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.02,
                callbackCount: 120,
                deliveredFrameCount: 119,
                skippedFrameCount: 1,
                observedFrameRate: 114.0,
                deliveryRatio: 0.95,
                firstFrameLatency: 0.03
            ),
            errorDescription: nil
        )

        let assessment = MDKCaptureBenchmarkJudge.assess(measurement: measurement, target: target)

        XCTAssertTrue(assessment.passed)
        XCTAssertTrue(assessment.failedExpectations.isEmpty)
        XCTAssertTrue(assessment.summary.hasPrefix("PASS"))
    }

    func testJudgeFailsMeasurementWhenThresholdsAreMissed() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let measurement = MDKCaptureBenchmarkMeasurement(
            backend: .cgDisplayStream,
            available: true,
            reason: "Primary backend available.",
            result: MDKCaptureBenchmarkResult(
                backend: .cgDisplayStream,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.20,
                callbackCount: 90,
                deliveredFrameCount: 80,
                skippedFrameCount: 10,
                observedFrameRate: 80.0,
                deliveryRatio: 0.66,
                firstFrameLatency: 0.12
            ),
            errorDescription: nil
        )

        let assessment = MDKCaptureBenchmarkJudge.assess(measurement: measurement, target: target)

        XCTAssertFalse(assessment.passed)
        XCTAssertEqual(assessment.failedExpectations.count, 3)
        XCTAssertTrue(assessment.summary.hasPrefix("FAIL"))
    }

    func testSuiteAssessmentRespectsPlanIntent() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let failingMeasurement = MDKCaptureBenchmarkMeasurement(
            backend: .cgDisplayStream,
            available: true,
            reason: "Primary backend available.",
            result: MDKCaptureBenchmarkResult(
                backend: .cgDisplayStream,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.0,
                callbackCount: 60,
                deliveredFrameCount: 60,
                skippedFrameCount: 0,
                observedFrameRate: 60.0,
                deliveryRatio: 0.50,
                firstFrameLatency: 0.11
            ),
            errorDescription: nil
        )
        let passingMeasurement = MDKCaptureBenchmarkMeasurement(
            backend: .avFoundation,
            available: true,
            reason: "Fallback available.",
            result: MDKCaptureBenchmarkResult(
                backend: .avFoundation,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.0,
                callbackCount: 120,
                deliveredFrameCount: 118,
                skippedFrameCount: 2,
                observedFrameRate: 114.0,
                deliveryRatio: 0.95,
                firstFrameLatency: 0.04
            ),
            errorDescription: nil
        )

        let validateSuite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .validateDefaultBackend,
                candidates: []
            ),
            pixelFormat: 0x78343230,
            sampleDuration: 1.0,
            measurements: [failingMeasurement, passingMeasurement]
        )
        let compareSuite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .compareBackends,
                candidates: []
            ),
            pixelFormat: 0x78343230,
            sampleDuration: 1.0,
            measurements: [failingMeasurement, passingMeasurement]
        )

        XCTAssertFalse(validateSuite.assessment.passed)
        XCTAssertTrue(compareSuite.assessment.passed)
    }

    func testOptimizationTargetsExposeStableIdentifiers() {
        XCTAssertEqual(
            MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly.identifier,
            "uhd-hdr-120-capture-only"
        )
        XCTAssertEqual(
            MDKCaptureOptimizationTargets.target(identifier: "qhd-hdr-120-virtual-display")?.name,
            "QHD HDR 120 Virtual Display"
        )
    }

    func testSuiteReportEncodesAssessmentAndMeasurementMetrics() throws {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let suite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .validateDefaultBackend,
                candidates: []
            ),
            pixelFormat: 0x78343230,
            sampleDuration: 1.0,
            measurements: [
                MDKCaptureBenchmarkMeasurement(
                    backend: .cgDisplayStream,
                    available: true,
                    reason: "Primary backend available.",
                    result: MDKCaptureBenchmarkResult(
                        backend: .cgDisplayStream,
                        requestedFrameRate: 120,
                        requestedSampleDuration: 1.0,
                        measuredDuration: 1.02,
                        callbackCount: 120,
                        deliveredFrameCount: 119,
                        skippedFrameCount: 1,
                        observedFrameRate: 114.0,
                        deliveryRatio: 0.95,
                        firstFrameLatency: 0.03
                    ),
                    errorDescription: nil
                )
            ]
        )

        let report = MDKCaptureBenchmarkReport.make(from: suite)
        let jsonData = try MDKCaptureBenchmarkReport.jsonData(for: suite)
        let decoded = try JSONDecoder().decode(MDKCaptureBenchmarkSuiteReport.self, from: jsonData)

        XCTAssertEqual(report.targetIdentifier, "uhd-hdr-120-capture-only")
        XCTAssertTrue(report.suitePassed)
        XCTAssertEqual(report.measurements.count, 1)
        XCTAssertEqual(report.measurements[0].backend, "cgdisplaystream")
        XCTAssertEqual(report.measurements[0].observedFrameRate ?? -1, 114.0, accuracy: 0.001)
        XCTAssertEqual(decoded, report)
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
