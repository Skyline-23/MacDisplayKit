import CoreVideo
import Foundation
import MacDisplayKit

final class MDKHostBenchmarkController {
    static let benchmarkPixelFormat = UInt32(kCVPixelFormatType_32BGRA)

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
            pixelFormat: Self.benchmarkPixelFormat,
            sampleDuration: 1.0
        )
    }
}
