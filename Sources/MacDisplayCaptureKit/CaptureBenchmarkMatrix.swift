import Foundation

@objcMembers
public final class MDKCaptureBenchmarkMatrixResult: NSObject {
    public let display: MDKDisplayDescriptor
    public let intent: MDKCapturePlanIntent
    public let suites: [MDKCaptureBenchmarkSuiteResult]

    public init(
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        suites: [MDKCaptureBenchmarkSuiteResult]
    ) {
        self.display = display
        self.intent = intent
        self.suites = suites
        super.init()
    }

    public var passed: Bool {
        suites.allSatisfy { $0.assessment.passed }
    }
}

public enum MDKCaptureBenchmarkMatrixRunner {
    public static func runCaptureOnlyValidationMatrix(
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        warmupDuration: TimeInterval = 1.0,
        sampleDuration: TimeInterval = 1.0
    ) -> MDKCaptureBenchmarkMatrixResult {
        run(
            display: display,
            targets: MDKCaptureOptimizationTargets.captureOnlyValidationTargets,
            intent: intent,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration
        )
    }

    public static func run(
        display: MDKDisplayDescriptor,
        targets: [MDKCaptureOptimizationTarget],
        intent: MDKCapturePlanIntent,
        warmupDuration: TimeInterval = 1.0,
        sampleDuration: TimeInterval = 1.0
    ) -> MDKCaptureBenchmarkMatrixResult {
        run(
            display: display,
            targets: targets,
            intent: intent,
            warmupDuration: warmupDuration,
            sampleDuration: sampleDuration,
            runBenchmark: { configuration, warmupDuration, sampleDuration in
                try MDKCaptureBenchmarkRunner.run(
                    configuration: configuration,
                    warmupDuration: warmupDuration,
                    sampleDuration: sampleDuration
                )
            },
            availabilityProvider: MDKCaptureBackendProbe.availability(for:target:)
        )
    }

    static func run(
        display: MDKDisplayDescriptor,
        targets: [MDKCaptureOptimizationTarget],
        intent: MDKCapturePlanIntent,
        warmupDuration: TimeInterval,
        sampleDuration: TimeInterval,
        runBenchmark: (MDKCaptureConfiguration, TimeInterval, TimeInterval) throws -> MDKCaptureBenchmarkResult,
        availabilityProvider: (MDKDisplayDescriptor, MDKCaptureOptimizationTarget) -> MDKCaptureBackendAvailability
    ) -> MDKCaptureBenchmarkMatrixResult {
        let suites = targets.map { target in
            let availability = availabilityProvider(display, target)
            let plan = MDKCaptureBenchmarkPlanner.plan(
                for: display,
                target: target,
                intent: intent,
                availability: availability
            )

            return MDKCaptureBenchmarkSuiteRunner.run(
                plan: plan,
                pixelFormat: target.benchmarkPixelFormat,
                warmupDuration: warmupDuration,
                sampleDuration: sampleDuration,
                runBenchmark: runBenchmark
            )
        }

        return MDKCaptureBenchmarkMatrixResult(display: display, intent: intent, suites: suites)
    }
}
