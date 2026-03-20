import Foundation

public struct MDKCaptureBenchmarkMeasurementReport: Codable, Equatable, Sendable {
    public let backend: String
    public let available: Bool
    public let passed: Bool
    public let reason: String
    public let summary: String
    public let errorDescription: String?
    public let failedExpectations: [String]
    public let requestedFrameRate: Int?
    public let requestedSampleDuration: TimeInterval?
    public let measuredDuration: TimeInterval?
    public let callbackCount: UInt64?
    public let deliveredFrameCount: UInt64?
    public let skippedFrameCount: UInt64?
    public let observedFrameRate: Double?
    public let deliveryRatio: Double?
    public let firstFrameLatency: TimeInterval?
}

public struct MDKCaptureBenchmarkSuiteReport: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let displayName: String
    public let targetIdentifier: String
    public let targetName: String
    public let topology: String
    public let intent: String
    public let pixelFormat: UInt32
    public let sampleDuration: TimeInterval
    public let suitePassed: Bool
    public let minimumObservedFrameRateRatio: Double
    public let minimumDeliveryRatio: Double
    public let maximumFirstFrameLatency: TimeInterval
    public let measurements: [MDKCaptureBenchmarkMeasurementReport]
}

public enum MDKCaptureBenchmarkReport {
    public static func make(from suite: MDKCaptureBenchmarkSuiteResult) -> MDKCaptureBenchmarkSuiteReport {
        let assessment = suite.assessment
        let thresholds = suite.plan.target.acceptanceThresholds

        let measurements = zip(suite.measurements, assessment.measurements).map { measurement, measurementAssessment in
            let result = measurement.result
            return MDKCaptureBenchmarkMeasurementReport(
                backend: backendName(measurement.backend),
                available: measurement.available,
                passed: measurementAssessment.passed,
                reason: measurement.reason,
                summary: measurementAssessment.summary,
                errorDescription: measurement.errorDescription,
                failedExpectations: measurementAssessment.failedExpectations,
                requestedFrameRate: result?.requestedFrameRate,
                requestedSampleDuration: result?.requestedSampleDuration,
                measuredDuration: result?.measuredDuration,
                callbackCount: result?.callbackCount,
                deliveredFrameCount: result?.deliveredFrameCount,
                skippedFrameCount: result?.skippedFrameCount,
                observedFrameRate: result?.observedFrameRate,
                deliveryRatio: result?.deliveryRatio,
                firstFrameLatency: result?.firstFrameLatency
            )
        }

        return MDKCaptureBenchmarkSuiteReport(
            displayID: suite.plan.display.id,
            displayName: suite.plan.display.localizedName,
            targetIdentifier: suite.plan.target.identifier,
            targetName: suite.plan.target.name,
            topology: topologyName(suite.plan.target.topology),
            intent: intentName(suite.plan.intent),
            pixelFormat: suite.pixelFormat,
            sampleDuration: suite.sampleDuration,
            suitePassed: assessment.passed,
            minimumObservedFrameRateRatio: thresholds.minimumObservedFrameRateRatio,
            minimumDeliveryRatio: thresholds.minimumDeliveryRatio,
            maximumFirstFrameLatency: thresholds.maximumFirstFrameLatency,
            measurements: measurements
        )
    }

    public static func jsonData(
        for suite: MDKCaptureBenchmarkSuiteResult,
        prettyPrinted: Bool = true,
        sortedKeys: Bool = true
    ) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        if sortedKeys {
            encoder.outputFormatting.insert(.sortedKeys)
        }
        return try encoder.encode(make(from: suite))
    }

    private static func backendName(_ backend: MDKCaptureBackend) -> String {
        switch backend {
        case .avFoundation:
            return "avfoundation"
        case .cgDisplayStream:
            return "cgdisplaystream"
        }
    }

    private static func topologyName(_ topology: MDKCaptureScenarioTopology) -> String {
        switch topology {
        case .captureOnly:
            return "capture-only"
        case .virtualDisplay:
            return "virtual-display"
        }
    }

    private static func intentName(_ intent: MDKCapturePlanIntent) -> String {
        switch intent {
        case .validateDefaultBackend:
            return "validate-default-backend"
        case .compareBackends:
            return "compare-backends"
        }
    }
}
