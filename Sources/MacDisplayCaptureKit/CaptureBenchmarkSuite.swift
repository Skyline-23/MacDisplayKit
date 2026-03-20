import Foundation

@objcMembers
public final class MDKCaptureBenchmarkMeasurement: NSObject {
    public let backend: MDKCaptureBackend
    public let available: Bool
    public let reason: String
    public let result: MDKCaptureBenchmarkResult?
    public let errorDescription: String?

    public init(
        backend: MDKCaptureBackend,
        available: Bool,
        reason: String,
        result: MDKCaptureBenchmarkResult?,
        errorDescription: String?
    ) {
        self.backend = backend
        self.available = available
        self.reason = reason
        self.result = result
        self.errorDescription = errorDescription
        super.init()
    }
}

@objcMembers
public final class MDKCaptureBenchmarkSuiteResult: NSObject {
    public let plan: MDKCaptureBenchmarkPlan
    public let pixelFormat: UInt32
    public let sampleDuration: TimeInterval
    public let measurements: [MDKCaptureBenchmarkMeasurement]

    public init(
        plan: MDKCaptureBenchmarkPlan,
        pixelFormat: UInt32,
        sampleDuration: TimeInterval,
        measurements: [MDKCaptureBenchmarkMeasurement]
    ) {
        self.plan = plan
        self.pixelFormat = pixelFormat
        self.sampleDuration = sampleDuration
        self.measurements = measurements
        super.init()
    }

    public var successfulMeasurements: [MDKCaptureBenchmarkMeasurement] {
        measurements.filter { $0.result != nil }
    }
}

public enum MDKCaptureBenchmarkSuiteRunner {
    public static func run(
        plan: MDKCaptureBenchmarkPlan,
        pixelFormat: UInt32,
        sampleDuration: TimeInterval = 1.0
    ) -> MDKCaptureBenchmarkSuiteResult {
        run(
            plan: plan,
            pixelFormat: pixelFormat,
            sampleDuration: sampleDuration,
            runBenchmark: { configuration, duration in
                try MDKCaptureBenchmarkRunner.run(
                    configuration: configuration,
                    sampleDuration: duration
                )
            }
        )
    }

    static func run(
        plan: MDKCaptureBenchmarkPlan,
        pixelFormat: UInt32,
        sampleDuration: TimeInterval,
        runBenchmark: (MDKCaptureConfiguration, TimeInterval) throws -> MDKCaptureBenchmarkResult
    ) -> MDKCaptureBenchmarkSuiteResult {
        let measurements = plan.candidates.map { candidate in
            guard candidate.available else {
                return MDKCaptureBenchmarkMeasurement(
                    backend: candidate.backend,
                    available: false,
                    reason: candidate.reason,
                    result: nil,
                    errorDescription: nil
                )
            }

            let configuration = plan.target.makeConfiguration(
                displayID: plan.display.id,
                pixelFormat: pixelFormat,
                backend: candidate.backend
            )

            do {
                let result = try runBenchmark(configuration, sampleDuration)
                return MDKCaptureBenchmarkMeasurement(
                    backend: candidate.backend,
                    available: true,
                    reason: candidate.reason,
                    result: result,
                    errorDescription: nil
                )
            } catch {
                return MDKCaptureBenchmarkMeasurement(
                    backend: candidate.backend,
                    available: true,
                    reason: candidate.reason,
                    result: nil,
                    errorDescription: String(describing: error)
                )
            }
        }

        return MDKCaptureBenchmarkSuiteResult(
            plan: plan,
            pixelFormat: pixelFormat,
            sampleDuration: sampleDuration,
            measurements: measurements
        )
    }
}
