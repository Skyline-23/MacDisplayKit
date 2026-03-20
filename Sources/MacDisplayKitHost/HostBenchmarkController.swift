import Foundation
import MacDisplayKit

final class MDKHostBenchmarkController {
    static let benchmarkWarmupDuration: TimeInterval = 1.0
    static let benchmarkSampleDuration: TimeInterval = 3.0

    func availableDisplays() -> [MDKDisplayDescriptor] {
        MDKCaptureDiscovery.displays()
    }

    func availableTargets() -> [MDKCaptureOptimizationTarget] {
        MDKCapabilityMatrix.optimizationTargets()
    }

    func display(id: UInt32) -> MDKDisplayDescriptor? {
        availableDisplays().first { $0.id == id }
    }

    func target(identifier: String) -> MDKCaptureOptimizationTarget? {
        MDKCaptureOptimizationTargets.target(identifier: identifier)
    }

    func runBenchmark(
        display: MDKDisplayDescriptor,
        target: MDKCaptureOptimizationTarget,
        intent: MDKCapturePlanIntent
    ) -> MDKCaptureBenchmarkSuiteResult {
        let availability = MDKCaptureBackendProbe.availability(for: display, target: target)
        let plan = MDKCaptureBenchmarkPlanner.plan(
            for: display,
            target: target,
            intent: intent,
            availability: availability
        )

        return MDKCaptureBenchmarkSuiteRunner.run(
            plan: plan,
            pixelFormat: target.benchmarkPixelFormat,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }

    func runCaptureOnlyValidationMatrix(
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent
    ) -> MDKCaptureBenchmarkMatrixResult {
        MDKCaptureBenchmarkMatrixRunner.runCaptureOnlyValidationMatrix(
            display: display,
            intent: intent,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }
}
