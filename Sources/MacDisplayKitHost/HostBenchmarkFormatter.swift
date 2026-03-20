import Foundation
import MacDisplayKit

enum MDKHostBenchmarkFormatter {
    static func formatPrivateCapturePrototypePlan(
        _ plan: MDKPrivateCapturePrototypePlan
    ) -> String {
        var lines: [String] = []
        lines.append("Private hardware capture prototype plan")
        lines.append("Recommended entry point: \(plan.recommendedEntryPoint.displayName)")
        lines.append("Ready for IOSurface prototype: \(plan.readyForIOSurfacePrototype ? "yes" : "no")")
        lines.append("Desktop capture available: \(plan.capabilities.desktopCaptureAvailable ? "yes" : "no")")
        lines.append("Display->IOSurface available: \(plan.capabilities.displayIOSurfaceCaptureAvailable ? "yes" : "no")")
        lines.append("Display->IOSurface+options available: \(plan.capabilities.displayIOSurfaceCaptureWithOptionsAvailable ? "yes" : "no")")
        lines.append("Extended range option available: \(plan.capabilities.extendedRangeOptionAvailable ? "yes" : "no")")
        lines.append("")
        lines.append("Notes:")
        for note in plan.recommendedNotes {
            lines.append("  - \(note)")
        }
        return lines.joined(separator: "\n")
    }

    static func formatReport(for suite: MDKCaptureBenchmarkSuiteResult) -> String {
        let assessment = suite.assessment
        var lines: [String] = []
        lines.append("Display: \(suite.plan.display.localizedName) (\(suite.plan.display.id))")
        lines.append("Target: \(suite.plan.target.name)")
        lines.append("Target ID: \(suite.plan.target.identifier)")
        lines.append("Intent: \(suite.plan.intent == .compareBackends ? "compare-backends" : "validate-default-backend")")
        lines.append("Processing path: \(suite.processingMode.rawValue)")
        lines.append("Screen capture access: \(suite.plan.screenCaptureAccessAuthorized ? "authorized" : "not authorized")")
        lines.append("Warmup duration: \(String(format: "%.2fs", suite.warmupDuration))")
        lines.append("Sample duration: \(String(format: "%.2fs", suite.sampleDuration))")
        lines.append("Pixel format: \(String(format: "0x%08X", suite.pixelFormat))")
        lines.append("Suite result: \(assessment.passed ? "PASS" : "FAIL")")
        lines.append(
            String(
                format: "Thresholds: fps>=%.0f%% delivery>=%.0f%% first-frame<=%.0fms",
                suite.plan.target.acceptanceThresholds.minimumObservedFrameRateRatio * 100,
                suite.plan.target.acceptanceThresholds.minimumDeliveryRatio * 100,
                suite.plan.target.acceptanceThresholds.maximumFirstFrameLatency * 1000
            )
        )
        lines.append("")

        for (measurement, measurementAssessment) in zip(suite.measurements, assessment.measurements) {
            lines.append("Backend: \(backendName(measurement.backend))")
            lines.append("Available: \(measurement.available ? "yes" : "no")")
            lines.append("Assessment: \(measurementAssessment.passed ? "PASS" : "FAIL")")
            lines.append("Reason: \(measurement.reason)")
            if let result = measurement.result {
                lines.append("Observed FPS: \(String(format: "%.2f", result.observedFrameRate))")
                lines.append("Delivered frames: \(result.deliveredFrameCount)")
                lines.append("Skipped callbacks: \(result.skippedFrameCount)")
                lines.append("Delivery ratio: \(String(format: "%.3f", result.deliveryRatio))")
                if let firstFrameLatency = result.firstFrameLatency {
                    lines.append("First frame latency: \(String(format: "%.3fs", firstFrameLatency))")
                }
                lines.append("Processed frames: \(result.processedFrameCount)")
                lines.append("Processing failures: \(result.processingFailureCount)")
                lines.append("Processed FPS: \(String(format: "%.2f", result.processedFrameRate))")
                lines.append("Processed ratio: \(String(format: "%.3f", result.processedFrameRatio))")
            }
            lines.append("Summary: \(measurementAssessment.summary)")
            if !measurementAssessment.failedExpectations.isEmpty {
                lines.append("Failed expectations:")
                for expectation in measurementAssessment.failedExpectations {
                    lines.append("  - \(expectation)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func backendName(_ backend: MDKCaptureBackend) -> String {
        switch backend {
        case .avFoundation:
            return "AVFoundation"
        case .cgDisplayStream:
            return "CGDisplayStream"
        @unknown default:
            return "Unknown"
        }
    }
}
