import Foundation
import MacDisplayKit
import MacDisplayCaptureKit

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
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode
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
            processingMode: processingMode,
            pixelFormat: target.benchmarkPixelFormat,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }

    func runCaptureOnlyValidationMatrix(
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) -> MDKCaptureBenchmarkMatrixResult {
        MDKCaptureBenchmarkMatrixRunner.runCaptureOnlyValidationMatrix(
            display: display,
            intent: intent,
            processingMode: processingMode,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }

    func privateCapturePrototypePlan() -> MDKPrivateCapturePrototypePlan {
        MDKCapabilityMatrix.privateCapturePrototypePlan()
    }

    func probePrivateCaptureSingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.captureSingleFrame(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange
        )
    }

    func probePrivateProxyCaptureSingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.captureProxySingleFrame(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange
        )
    }

    func probePrivateDisplayStream(
        displayID: UInt32
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.createDisplayStream(displayID: displayID)
    }

    func probePrivateDisplayStream(
        displayID: UInt32,
        configuration: MDKPrivateDisplayStreamProbeConfiguration
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.createDisplayStream(
            displayID: displayID,
            configuration: configuration
        )
    }

    func probePrivateDisplayStreamMatrix(
        displayID: UInt32
    ) throws -> [MDKPrivateCaptureProbeResult] {
        try MDKPrivateCapturePrototypeProbe.createDisplayStreamMatrix(displayID: displayID)
    }

    func benchmarkPrivateCapture(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        try MDKPrivateCapturePrototypeBenchmark.run(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange,
            sampleDuration: sampleDuration
        )
    }

    func benchmarkPrivateProxyCapture(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        try MDKPrivateCapturePrototypeBenchmark.runProxy(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange,
            sampleDuration: sampleDuration
        )
    }

    func traceScreenCaptureKitProxyHandshake(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitProxyHandshakeTrace {
        try MDKScreenCaptureKitProxyHandshakeTracer.trace(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func traceScreenCaptureKitPassiveHandshake(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitProxyHandshakeTrace {
        try MDKScreenCaptureKitProxyHandshakeTracer.tracePassive(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func traceScreenCaptureKitTiming(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitTimingTrace {
        try MDKScreenCaptureKitTimingTracer.trace(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func inspectScreenCaptureKitRuntime() throws -> MDKScreenCaptureKitRuntimeInventory {
        try MDKScreenCaptureKitRuntimeInspector.inspect()
    }
}
