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
    public let processingMode: MDKCaptureBenchmarkProcessingMode
    public let pixelFormat: UInt32
    public let warmupDuration: TimeInterval
    public let sampleDuration: TimeInterval
    public let measurements: [MDKCaptureBenchmarkMeasurement]

    public init(
        plan: MDKCaptureBenchmarkPlan,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        pixelFormat: UInt32,
        warmupDuration: TimeInterval,
        sampleDuration: TimeInterval,
        measurements: [MDKCaptureBenchmarkMeasurement]
    ) {
        self.plan = plan
        self.processingMode = processingMode
        self.pixelFormat = pixelFormat
        self.warmupDuration = warmupDuration
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
        processingMode: MDKCaptureBenchmarkProcessingMode = .metalCopy,
        pixelFormat: UInt32,
        warmupDuration: TimeInterval = 1.0,
        sampleDuration: TimeInterval = 1.0
    ) -> MDKCaptureBenchmarkSuiteResult {
        run(
            plan: plan,
            processingMode: processingMode,
            pixelFormat: pixelFormat,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration,
            runBenchmark: { configuration, warmupDuration, sampleDuration in
                try MDKCaptureBenchmarkRunner.run(
                    configuration: configuration,
                    processingMode: processingMode,
                    warmupDuration: warmupDuration,
                    sampleDuration: sampleDuration
                )
            }
        )
    }

    static func run(
        plan: MDKCaptureBenchmarkPlan,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        pixelFormat: UInt32,
        warmupDuration: TimeInterval,
        sampleDuration: TimeInterval,
        runBenchmark: (MDKCaptureConfiguration, TimeInterval, TimeInterval) throws -> MDKCaptureBenchmarkResult
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
                let result = try runBenchmark(configuration, warmupDuration, sampleDuration)
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
            processingMode: processingMode,
            pixelFormat: pixelFormat,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration,
            measurements: measurements
        )
    }
}
