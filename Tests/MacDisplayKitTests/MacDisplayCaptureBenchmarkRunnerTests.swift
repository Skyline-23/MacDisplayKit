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
            processingMode: .metalCopy,
            stats: stats,
            processing: MDKCaptureBenchmarkProcessingSnapshot(
                processedFrameCount: 120,
                processingFailureCount: 0
            ),
            deliveredFrame: MDKCaptureBenchmarkFrameSnapshot(
                width: 3840,
                height: 2160,
                pixelFormat: 0x78343230
            ),
            sampleDuration: 1.0,
            measuredDuration: 1.2,
            timeline: timeline,
            runStartedAt: 10.0
        )

        XCTAssertEqual(result.backend, MDKCaptureBackend.cgDisplayStream)
        XCTAssertEqual(result.processingMode, MDKCaptureBenchmarkProcessingMode.metalCopy)
        XCTAssertEqual(result.callbackCount, 132)
        XCTAssertEqual(result.deliveredFrameCount, 120)
        XCTAssertEqual(result.skippedFrameCount, 12)
        XCTAssertEqual(result.observedFrameRate, 120.0, accuracy: 0.05)
        XCTAssertEqual(result.deliveryRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.firstFrameLatency ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.processedFrameCount, 120)
        XCTAssertEqual(result.processingFailureCount, 0)
        XCTAssertEqual(
            result.processedFrameRate,
            Double(result.processedFrameCount) / (11.0916666667 - 10.1),
            accuracy: 0.001
        )
        XCTAssertEqual(result.processedFrameRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.deliveredFrameWidth, 3840)
        XCTAssertEqual(result.deliveredFrameHeight, 2160)
        XCTAssertEqual(result.deliveredPixelFormat, 0x78343230)
        XCTAssertEqual(result.deliveredFrameMatchesRequest, true)
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
            processingMode: .metalCopy,
            stats: stats,
            processing: MDKCaptureBenchmarkProcessingSnapshot(
                processedFrameCount: 1,
                processingFailureCount: 0
            ),
            deliveredFrame: MDKCaptureBenchmarkFrameSnapshot(
                width: nil,
                height: nil,
                pixelFormat: nil
            ),
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
        let processor = FakeFrameProcessor()
        let timeBox = FakeTimeBox(initial: 20.0)

        let result = try MDKCaptureBenchmarkRunner.run(
            configuration: configuration,
            processingMode: .metalCopy,
            warmupDuration: 0,
            sampleDuration: 1.0,
            makeSession: { _ in session },
            makeProcessor: { processor },
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
        XCTAssertEqual(result.processedFrameCount, 2)
        XCTAssertEqual(result.processingFailureCount, 0)
        XCTAssertEqual(result.processedFrameRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(processor.processedFrameCount, 2)
        XCTAssertFalse(session.isRunning)
    }

    func testSuiteRunnerCollectsAvailableCandidatesAndSkipsUnavailableOnes() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let plan = MDKCaptureBenchmarkPlan(
            target: target,
            display: display,
            intent: .compareBackends,
            screenCaptureAccessAuthorized: true,
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
            processingMode: .metalCopy,
            pixelFormat: 0x78343230,
            warmupDuration: 0,
            sampleDuration: 1.0,
            runBenchmark: { configuration, warmupDuration, sampleDuration in
                XCTAssertEqual(configuration.backend, .cgDisplayStream)
                XCTAssertEqual(warmupDuration, 0, accuracy: 0.0001)
                XCTAssertEqual(sampleDuration, 1.0, accuracy: 0.0001)
                return MDKCaptureBenchmarkResult(
                    backend: configuration.backend,
                    processingMode: .metalCopy,
                    requestedFrameRate: configuration.frameRate,
                    requestedSampleDuration: sampleDuration,
                    measuredDuration: 1.05,
                    callbackCount: 120,
                    deliveredFrameCount: 118,
                    skippedFrameCount: 2,
                    observedFrameRate: 117.7,
                    deliveryRatio: 117.7 / 120.0,
                    firstFrameLatency: 0.02,
                    processedFrameCount: 118,
                    processingFailureCount: 0,
                    processedFrameRate: 117.7,
                    processedFrameRatio: 1.0,
                    deliveredFrameWidth: configuration.width,
                    deliveredFrameHeight: configuration.height,
                    deliveredPixelFormat: configuration.pixelFormat,
                    deliveredFrameMatchesRequest: true
                )
            }
        )

        XCTAssertEqual(suite.measurements.count, 2)
        XCTAssertEqual(suite.successfulMeasurements.count, 1)
        XCTAssertEqual(suite.measurements[0].backend, MDKCaptureBackend.cgDisplayStream)
        XCTAssertNotNil(suite.measurements[0].result)
        XCTAssertNil(suite.measurements[0].errorDescription)
        XCTAssertEqual(suite.measurements[1].backend, MDKCaptureBackend.avFoundation)
        XCTAssertNil(suite.measurements[1].result)
        XCTAssertFalse(suite.measurements[1].available)
    }

    func testCaptureOnlyValidationMatrixRunsTargetsInCatalogOrder() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let targetIDs = MDKCaptureOptimizationTargets.captureOnlyValidationTargets.map(\.identifier)
        var observedTargetIDs: [String] = []

        let matrix = MDKCaptureBenchmarkMatrixRunner.run(
            display: display,
            targets: MDKCaptureOptimizationTargets.captureOnlyValidationTargets,
            intent: .compareBackends,
            processingMode: .metalCopy,
            warmupDuration: 0,
            sampleDuration: 1.0
        ) { configuration, warmupDuration, sampleDuration in
            let target = MDKCaptureOptimizationTargets.captureOnlyValidationTargets.first {
                $0.width == configuration.width &&
                $0.height == configuration.height &&
                $0.frameRate == configuration.frameRate &&
                $0.dynamicRangeMode == configuration.dynamicRangeMode
            }
            observedTargetIDs.append(target?.identifier ?? "unknown")
            XCTAssertEqual(warmupDuration, 0, accuracy: 0.0001)
            XCTAssertEqual(sampleDuration, 1.0, accuracy: 0.0001)

            return MDKCaptureBenchmarkResult(
                backend: configuration.backend,
                processingMode: .metalCopy,
                requestedFrameRate: configuration.frameRate,
                requestedSampleDuration: sampleDuration,
                measuredDuration: 1.0,
                callbackCount: UInt64(configuration.frameRate),
                deliveredFrameCount: UInt64(configuration.frameRate),
                skippedFrameCount: 0,
                observedFrameRate: Double(configuration.frameRate),
                deliveryRatio: 1.0,
                firstFrameLatency: 0.01,
                processedFrameCount: UInt64(configuration.frameRate),
                processingFailureCount: 0,
                processedFrameRate: Double(configuration.frameRate),
                processedFrameRatio: 1.0,
                deliveredFrameWidth: configuration.width,
                deliveredFrameHeight: configuration.height,
                deliveredPixelFormat: configuration.pixelFormat,
                deliveredFrameMatchesRequest: true
            )
        } availabilityProvider: { _, _ in
            MDKCaptureBackendAvailability(
                screenCaptureAccessAuthorized: true,
                avFoundationAvailable: true,
                cgDisplayStreamAvailable: false
            )
        }

        XCTAssertEqual(matrix.suites.count, targetIDs.count)
        XCTAssertEqual(matrix.processingMode, .metalCopy)
        XCTAssertEqual(matrix.suites.map(\.plan.target.identifier), targetIDs)
        XCTAssertEqual(observedTargetIDs, targetIDs)
        XCTAssertTrue(matrix.passed)
    }

    func testJudgePassesMeasurementThatMeetsTargetThresholds() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let measurement = MDKCaptureBenchmarkMeasurement(
            backend: .cgDisplayStream,
            available: true,
            reason: "Primary backend available.",
            result: MDKCaptureBenchmarkResult(
                backend: .cgDisplayStream,
                processingMode: .metalCopy,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.02,
                callbackCount: 120,
                deliveredFrameCount: 119,
                skippedFrameCount: 1,
                observedFrameRate: 114.0,
                deliveryRatio: 0.95,
                firstFrameLatency: 0.03,
                processedFrameCount: 119,
                processingFailureCount: 0,
                processedFrameRate: 114.0,
                processedFrameRatio: 1.0,
                deliveredFrameWidth: 3840,
                deliveredFrameHeight: 2160,
                deliveredPixelFormat: 0x78343230,
                deliveredFrameMatchesRequest: true
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
                processingMode: .metalCopy,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.20,
                callbackCount: 90,
                deliveredFrameCount: 80,
                skippedFrameCount: 10,
                observedFrameRate: 80.0,
                deliveryRatio: 0.66,
                firstFrameLatency: 0.12,
                processedFrameCount: 76,
                processingFailureCount: 4,
                processedFrameRate: 76.0,
                processedFrameRatio: 0.95,
                deliveredFrameWidth: 3840,
                deliveredFrameHeight: 2160,
                deliveredPixelFormat: 0x78343230,
                deliveredFrameMatchesRequest: true
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
                processingMode: .metalCopy,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.0,
                callbackCount: 60,
                deliveredFrameCount: 60,
                skippedFrameCount: 0,
                observedFrameRate: 60.0,
                deliveryRatio: 0.50,
                firstFrameLatency: 0.11,
                processedFrameCount: 60,
                processingFailureCount: 0,
                processedFrameRate: 60.0,
                processedFrameRatio: 1.0,
                deliveredFrameWidth: 3840,
                deliveredFrameHeight: 2160,
                deliveredPixelFormat: 0x78343230,
                deliveredFrameMatchesRequest: true
            ),
            errorDescription: nil
        )
        let passingMeasurement = MDKCaptureBenchmarkMeasurement(
            backend: .avFoundation,
            available: true,
            reason: "Fallback available.",
            result: MDKCaptureBenchmarkResult(
                backend: .avFoundation,
                processingMode: .metalCopy,
                requestedFrameRate: 120,
                requestedSampleDuration: 1.0,
                measuredDuration: 1.0,
                callbackCount: 120,
                deliveredFrameCount: 118,
                skippedFrameCount: 2,
                observedFrameRate: 114.0,
                deliveryRatio: 0.95,
                firstFrameLatency: 0.04,
                processedFrameCount: 118,
                processingFailureCount: 0,
                processedFrameRate: 114.0,
                processedFrameRatio: 1.0,
                deliveredFrameWidth: 3840,
                deliveredFrameHeight: 2160,
                deliveredPixelFormat: 0x78343230,
                deliveredFrameMatchesRequest: true
            ),
            errorDescription: nil
        )

        let validateSuite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .validateDefaultBackend,
                screenCaptureAccessAuthorized: true,
                candidates: []
            ),
            processingMode: .metalCopy,
            pixelFormat: 0x78343230,
            warmupDuration: 1.0,
            sampleDuration: 1.0,
            measurements: [failingMeasurement, passingMeasurement]
        )
        let compareSuite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .compareBackends,
                screenCaptureAccessAuthorized: true,
                candidates: []
            ),
            processingMode: .metalCopy,
            pixelFormat: 0x78343230,
            warmupDuration: 1.0,
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
                screenCaptureAccessAuthorized: true,
                candidates: []
            ),
            processingMode: .metalCopy,
            pixelFormat: 0x78343230,
            warmupDuration: 1.0,
            sampleDuration: 1.0,
            measurements: [
                MDKCaptureBenchmarkMeasurement(
                    backend: .cgDisplayStream,
                    available: true,
                    reason: "Primary backend available.",
                    result: MDKCaptureBenchmarkResult(
                        backend: .cgDisplayStream,
                        processingMode: .metalCopy,
                        requestedFrameRate: 120,
                        requestedSampleDuration: 1.0,
                        measuredDuration: 1.02,
                        callbackCount: 120,
                        deliveredFrameCount: 119,
                        skippedFrameCount: 1,
                        observedFrameRate: 114.0,
                        deliveryRatio: 0.95,
                        firstFrameLatency: 0.03,
                        processedFrameCount: 119,
                        processingFailureCount: 0,
                        processedFrameRate: 114.0,
                        processedFrameRatio: 1.0,
                        deliveredFrameWidth: 3840,
                        deliveredFrameHeight: 2160,
                        deliveredPixelFormat: 0x78343230,
                        deliveredFrameMatchesRequest: true
                    ),
                    errorDescription: nil
                )
            ]
        )

        let report = MDKCaptureBenchmarkReport.make(from: suite)
        let jsonData = try MDKCaptureBenchmarkReport.jsonData(for: suite)
        let decoded = try JSONDecoder().decode(MDKCaptureBenchmarkSuiteReport.self, from: jsonData)

        XCTAssertEqual(report.targetIdentifier, "uhd-hdr-120-capture-only")
        XCTAssertEqual(report.processingMode, "metal-copy")
        XCTAssertTrue(report.screenCaptureAccessAuthorized)
        XCTAssertEqual(report.warmupDuration, 1.0, accuracy: 0.0001)
        XCTAssertTrue(report.suitePassed)
        XCTAssertEqual(report.measurements.count, 1)
        XCTAssertEqual(report.measurements[0].backend, "cgdisplaystream")
        XCTAssertEqual(report.measurements[0].processingMode, "metal-copy")
        XCTAssertEqual(report.measurements[0].observedFrameRate ?? -1, 114.0, accuracy: 0.001)
        XCTAssertEqual(report.measurements[0].processedFrameCount, 119)
        XCTAssertEqual(report.measurements[0].deliveredFrameWidth, 3840)
        XCTAssertEqual(report.measurements[0].deliveredFrameMatchesRequest, true)
        XCTAssertEqual(decoded, report)
    }

    func testMatrixReportEncodesGroupedSuiteReports() throws {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let suite = MDKCaptureBenchmarkSuiteResult(
            plan: MDKCaptureBenchmarkPlan(
                target: target,
                display: display,
                intent: .compareBackends,
                screenCaptureAccessAuthorized: true,
                candidates: []
            ),
            processingMode: .metalBind,
            pixelFormat: target.benchmarkPixelFormat,
            warmupDuration: 1.0,
            sampleDuration: 1.0,
            measurements: [
                MDKCaptureBenchmarkMeasurement(
                    backend: .avFoundation,
                    available: true,
                    reason: "Primary backend available.",
                    result: MDKCaptureBenchmarkResult(
                        backend: .avFoundation,
                        processingMode: .metalBind,
                        requestedFrameRate: 120,
                        requestedSampleDuration: 1.0,
                        measuredDuration: 1.02,
                        callbackCount: 120,
                        deliveredFrameCount: 118,
                        skippedFrameCount: 2,
                        observedFrameRate: 114.0,
                        deliveryRatio: 0.95,
                        firstFrameLatency: 0.03,
                        processedFrameCount: 118,
                        processingFailureCount: 0,
                        processedFrameRate: 114.0,
                        processedFrameRatio: 1.0,
                        deliveredFrameWidth: 3840,
                        deliveredFrameHeight: 2160,
                        deliveredPixelFormat: target.benchmarkPixelFormat,
                        deliveredFrameMatchesRequest: true
                    ),
                    errorDescription: nil
                )
            ]
        )
        let matrix = MDKCaptureBenchmarkMatrixResult(
            display: display,
            intent: .compareBackends,
            processingMode: .metalBind,
            suites: [suite]
        )

        let report = MDKCaptureBenchmarkReport.make(from: matrix)
        let jsonData = try MDKCaptureBenchmarkReport.jsonData(for: matrix)
        let decoded = try JSONDecoder().decode(MDKCaptureBenchmarkMatrixReport.self, from: jsonData)

        XCTAssertEqual(report.displayID, 77)
        XCTAssertEqual(report.intent, "compare-backends")
        XCTAssertEqual(report.processingMode, "metal-bind")
        XCTAssertEqual(report.suites.count, 1)
        XCTAssertEqual(report.suites[0].targetIdentifier, "uhd-hdr-120-capture-only")
        XCTAssertTrue(report.matrixPassed)
        XCTAssertEqual(decoded, report)
    }

    func testRunnerExcludesWarmupFramesFromBenchmarkStatistics() throws {
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
        let processor = FakeFrameProcessor()
        let timeBox = FakeTimeBox(initial: 100.0)

        let result = try MDKCaptureBenchmarkRunner.run(
            configuration: configuration,
            processingMode: .metalCopy,
            warmupDuration: 0.5,
            sampleDuration: 1.0,
            makeSession: { _ in session },
            makeProcessor: { processor },
            timeSource: { timeBox.currentTime },
            sleeper: { duration in
                switch duration {
                case 0.5:
                    timeBox.advance(by: 0.10)
                    session.emitFrame()
                    timeBox.advance(by: 0.10)
                    session.emitSkippedCallback()
                    timeBox.advance(by: 0.30)
                case 1.0:
                    timeBox.advance(by: 0.20)
                    session.emitFrame()
                    timeBox.advance(by: 0.20)
                    session.emitFrame()
                    timeBox.advance(by: 0.20)
                    session.emitSkippedCallback()
                    timeBox.advance(by: 0.40)
                default:
                    XCTFail("Unexpected sleep duration \(duration)")
                }
            }
        )

        XCTAssertEqual(result.deliveredFrameCount, 2)
        XCTAssertEqual(result.skippedFrameCount, 1)
        XCTAssertEqual(result.callbackCount, 3)
        XCTAssertEqual(result.observedFrameRate, 5.0, accuracy: 0.001)
        XCTAssertEqual(result.deliveryRatio, 5.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(result.firstFrameLatency ?? -1, 0.20, accuracy: 0.0001)
        XCTAssertEqual(result.processedFrameCount, 2)
        XCTAssertEqual(processor.processedFrameCount, 3)
    }

    func testRunnerRecordsProcessingFailuresSeparatelyFromCaptureDelivery() throws {
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
        let processor = FakeFrameProcessor(failingSequenceNumbers: [2])
        let timeBox = FakeTimeBox(initial: 30.0)

        let result = try MDKCaptureBenchmarkRunner.run(
            configuration: configuration,
            processingMode: .none,
            warmupDuration: 0,
            sampleDuration: 1.0,
            makeSession: { _ in session },
            makeProcessor: { processor },
            timeSource: { timeBox.currentTime },
            sleeper: { duration in
                timeBox.advance(by: 0.10)
                session.emitFrame()
                timeBox.advance(by: 0.10)
                session.emitFrame()
                timeBox.advance(by: max(duration - 0.20, 0))
            }
        )

        XCTAssertEqual(result.deliveredFrameCount, 2)
        XCTAssertEqual(result.processedFrameCount, 1)
        XCTAssertEqual(result.processingFailureCount, 1)
        XCTAssertEqual(result.processedFrameRatio, 0.5, accuracy: 0.001)
    }

    func testPlannerMarksBackendsUnavailableWhenScreenCapturePermissionIsMissing() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let availability = MDKCaptureBackendAvailability(
            screenCaptureAccessAuthorized: false,
            avFoundationAvailable: true,
            cgDisplayStreamAvailable: true
        )

        let plan = MDKCaptureBenchmarkPlanner.plan(
            for: display,
            target: target,
            availability: availability
        )

        XCTAssertFalse(plan.screenCaptureAccessAuthorized)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertFalse(plan.candidates[0].available)
        XCTAssertFalse(plan.candidates[1].available)
        XCTAssertEqual(
            plan.candidates[0].reason,
            "Screen Recording permission is not granted for this host process."
        )
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

private final class FakeFrameProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    private(set) var processedFrameCount: UInt64 = 0
    private let failingSequenceNumbers: Set<UInt64>

    init(failingSequenceNumbers: Set<UInt64> = []) {
        self.failingSequenceNumbers = failingSequenceNumbers
    }

    func process(frame: MDKCaptureFrame) throws {
        if failingSequenceNumbers.contains(frame.sequenceNumber) {
            throw MDKCaptureFrameProcessingError.surfaceUnavailable
        }
        processedFrameCount += 1
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
