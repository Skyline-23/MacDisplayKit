import Foundation

@objcMembers
public final class MDKCaptureBenchmarkThresholds: NSObject, NSCopying {
    public let minimumObservedFrameRateRatio: Double
    public let minimumDeliveryRatio: Double
    public let maximumFirstFrameLatency: TimeInterval

    public init(
        minimumObservedFrameRateRatio: Double,
        minimumDeliveryRatio: Double,
        maximumFirstFrameLatency: TimeInterval
    ) {
        self.minimumObservedFrameRateRatio = minimumObservedFrameRateRatio
        self.minimumDeliveryRatio = minimumDeliveryRatio
        self.maximumFirstFrameLatency = maximumFirstFrameLatency
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        MDKCaptureBenchmarkThresholds(
            minimumObservedFrameRateRatio: minimumObservedFrameRateRatio,
            minimumDeliveryRatio: minimumDeliveryRatio,
            maximumFirstFrameLatency: maximumFirstFrameLatency
        )
    }
}

@objcMembers
public final class MDKCaptureBenchmarkMeasurementAssessment: NSObject {
    public let backend: MDKCaptureBackend
    public let passed: Bool
    public let summary: String
    public let failedExpectations: [String]

    public init(
        backend: MDKCaptureBackend,
        passed: Bool,
        summary: String,
        failedExpectations: [String]
    ) {
        self.backend = backend
        self.passed = passed
        self.summary = summary
        self.failedExpectations = failedExpectations
        super.init()
    }
}

@objcMembers
public final class MDKCaptureBenchmarkSuiteAssessment: NSObject {
    public let target: MDKCaptureOptimizationTarget
    public let intent: MDKCapturePlanIntent
    public let measurements: [MDKCaptureBenchmarkMeasurementAssessment]
    public let passed: Bool

    public init(
        target: MDKCaptureOptimizationTarget,
        intent: MDKCapturePlanIntent,
        measurements: [MDKCaptureBenchmarkMeasurementAssessment],
        passed: Bool
    ) {
        self.target = target
        self.intent = intent
        self.measurements = measurements
        self.passed = passed
        super.init()
    }
}

public enum MDKCaptureBenchmarkJudge {
    public static func assess(
        measurement: MDKCaptureBenchmarkMeasurement,
        target: MDKCaptureOptimizationTarget
    ) -> MDKCaptureBenchmarkMeasurementAssessment {
        guard measurement.available else {
            return MDKCaptureBenchmarkMeasurementAssessment(
                backend: measurement.backend,
                passed: false,
                summary: "Unavailable for this display.",
                failedExpectations: [measurement.reason]
            )
        }

        if let errorDescription = measurement.errorDescription {
            return MDKCaptureBenchmarkMeasurementAssessment(
                backend: measurement.backend,
                passed: false,
                summary: "Benchmark execution failed.",
                failedExpectations: [errorDescription]
            )
        }

        guard let result = measurement.result else {
            return MDKCaptureBenchmarkMeasurementAssessment(
                backend: measurement.backend,
                passed: false,
                summary: "No benchmark result was recorded.",
                failedExpectations: ["The backend did not return a measurement result."]
            )
        }

        let thresholds = target.acceptanceThresholds
        let minimumObservedFrameRate = Double(result.requestedFrameRate) * thresholds.minimumObservedFrameRateRatio
        var failures: [String] = []

        if result.observedFrameRate < minimumObservedFrameRate {
            failures.append(
                String(
                    format: "Observed FPS %.2f is below the %.2f threshold.",
                    result.observedFrameRate,
                    minimumObservedFrameRate
                )
            )
        }

        if result.deliveryRatio < thresholds.minimumDeliveryRatio {
            failures.append(
                String(
                    format: "Delivery ratio %.3f is below the %.3f threshold.",
                    result.deliveryRatio,
                    thresholds.minimumDeliveryRatio
                )
            )
        }

        if let firstFrameLatency = result.firstFrameLatency {
            if firstFrameLatency > thresholds.maximumFirstFrameLatency {
                failures.append(
                    String(
                        format: "First-frame latency %.3fs is above the %.3fs threshold.",
                        firstFrameLatency,
                        thresholds.maximumFirstFrameLatency
                    )
                )
            }
        } else {
            failures.append("First-frame latency is unavailable.")
        }

        let passed = failures.isEmpty
        let summary = passed
            ? String(
                format: "PASS at %.2f fps with %.3f delivery ratio.",
                result.observedFrameRate,
                result.deliveryRatio
            )
            : String(
                format: "FAIL at %.2f fps with %.3f delivery ratio.",
                result.observedFrameRate,
                result.deliveryRatio
            )

        return MDKCaptureBenchmarkMeasurementAssessment(
            backend: measurement.backend,
            passed: passed,
            summary: summary,
            failedExpectations: failures
        )
    }

    public static func assess(
        suite: MDKCaptureBenchmarkSuiteResult
    ) -> MDKCaptureBenchmarkSuiteAssessment {
        let assessments = suite.measurements.map { assess(measurement: $0, target: suite.plan.target) }
        let passed: Bool

        switch suite.plan.intent {
        case .validateDefaultBackend:
            passed = assessments.first?.passed ?? false
        case .compareBackends:
            passed = assessments.contains(where: \.passed)
        }

        return MDKCaptureBenchmarkSuiteAssessment(
            target: suite.plan.target,
            intent: suite.plan.intent,
            measurements: assessments,
            passed: passed
        )
    }
}

public extension MDKCaptureBenchmarkSuiteResult {
    var assessment: MDKCaptureBenchmarkSuiteAssessment {
        MDKCaptureBenchmarkJudge.assess(suite: self)
    }
}
