import Foundation
import CoreVideo

@objc
public enum MDKCaptureScenarioTopology: Int {
    case captureOnly = 0
    case virtualDisplay = 1
}

@objcMembers
public final class MDKCaptureOptimizationTarget: NSObject, NSCopying {
    public let identifier: String
    public let name: String
    public let topology: MDKCaptureScenarioTopology
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let dynamicRangeMode: MDKDynamicRangeMode
    public let recommendedBackend: MDKCaptureBackend
    public let acceptanceThresholds: MDKCaptureBenchmarkThresholds
    public let notes: [String]

    public init(
        identifier: String,
        name: String,
        topology: MDKCaptureScenarioTopology,
        width: Int,
        height: Int,
        frameRate: Int,
        dynamicRangeMode: MDKDynamicRangeMode,
        recommendedBackend: MDKCaptureBackend,
        acceptanceThresholds: MDKCaptureBenchmarkThresholds,
        notes: [String]
    ) {
        self.identifier = identifier
        self.name = name
        self.topology = topology
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.dynamicRangeMode = dynamicRangeMode
        self.recommendedBackend = recommendedBackend
        self.acceptanceThresholds = acceptanceThresholds
        self.notes = notes
        super.init()
    }

    public var requiresVirtualDisplay: Bool {
        topology == .virtualDisplay
    }

    public var benchmarkPixelFormat: UInt32 {
        switch dynamicRangeMode {
        case .sdr:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hdrCanonical, .hdrLocal:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }

    public func makeConfiguration(
        displayID: UInt32,
        pixelFormat: UInt32? = nil,
        backend: MDKCaptureBackend? = nil
    ) -> MDKCaptureConfiguration {
        MDKCaptureConfiguration(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat ?? benchmarkPixelFormat,
            backend: backend ?? recommendedBackend,
            dynamicRangeMode: dynamicRangeMode
        )
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        MDKCaptureOptimizationTarget(
            identifier: identifier,
            name: name,
            topology: topology,
            width: width,
            height: height,
            frameRate: frameRate,
            dynamicRangeMode: dynamicRangeMode,
            recommendedBackend: recommendedBackend,
            acceptanceThresholds: acceptanceThresholds,
            notes: notes
        )
    }
}

public enum MDKCaptureOptimizationTargets {
    public static var uhdHDR120CaptureOnly: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "uhd-hdr-120-capture-only",
            name: "UHD HDR 120 Capture Only",
            topology: .captureOnly,
            width: 3840,
            height: 2160,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .avFoundation,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.90,
                minimumDeliveryRatio: 0.92,
                maximumFirstFrameLatency: 0.080
            ),
            notes: [
                "Primary performance target for 4K HDR 120 capture.",
                "Prefer AVFoundation first when validating the primary native capture backend."
            ]
        )
    }

    public static var uhdHDR60CaptureOnly: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "uhd-hdr-60-capture-only",
            name: "UHD HDR 60 Capture Only",
            topology: .captureOnly,
            width: 3840,
            height: 2160,
            frameRate: 60,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .avFoundation,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.95,
                minimumDeliveryRatio: 0.96,
                maximumFirstFrameLatency: 0.080
            ),
            notes: [
                "Control target for isolating refresh-rate pressure from HDR throughput.",
                "Use this when validating whether a backend can sustain UHD HDR without the 120 Hz target."
            ]
        )
    }

    public static var uhdSDR120CaptureOnly: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "uhd-sdr-120-capture-only",
            name: "UHD SDR 120 Capture Only",
            topology: .captureOnly,
            width: 3840,
            height: 2160,
            frameRate: 120,
            dynamicRangeMode: .sdr,
            recommendedBackend: .avFoundation,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.92,
                minimumDeliveryRatio: 0.94,
                maximumFirstFrameLatency: 0.070
            ),
            notes: [
                "Control target for isolating HDR processing cost from UHD 120 capture.",
                "Use this before changing capture APIs when only SDR throughput is under test."
            ]
        )
    }

    public static var qhdHDR120CaptureOnly: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "qhd-hdr-120-capture-only",
            name: "QHD HDR 120 Capture Only",
            topology: .captureOnly,
            width: 2560,
            height: 1440,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .avFoundation,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.94,
                minimumDeliveryRatio: 0.95,
                maximumFirstFrameLatency: 0.070
            ),
            notes: [
                "Resolution step-down target for checking whether the capture API scales before UHD is reached.",
                "Use this target to separate bandwidth pressure from HDR cadence issues."
            ]
        )
    }

    public static var captureOnlyValidationTargets: [MDKCaptureOptimizationTarget] {
        [
            uhdHDR120CaptureOnly,
            uhdHDR60CaptureOnly,
            uhdSDR120CaptureOnly,
            qhdHDR120CaptureOnly
        ]
    }

    public static var uhdHDR120VirtualDisplay: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "uhd-hdr-120-virtual-display",
            name: "UHD HDR 120 Virtual Display",
            topology: .virtualDisplay,
            width: 3840,
            height: 2160,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .cgDisplayStream,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.85,
                minimumDeliveryRatio: 0.88,
                maximumFirstFrameLatency: 0.100
            ),
            notes: [
                "Stretch goal for virtual display capture at UHD HDR 120.",
                "Useful for measuring the combined cost of display synthesis and frame acquisition."
            ]
        )
    }

    public static var qhdHDR120VirtualDisplay: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            identifier: "qhd-hdr-120-virtual-display",
            name: "QHD HDR 120 Virtual Display",
            topology: .virtualDisplay,
            width: 2560,
            height: 1440,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .cgDisplayStream,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.88,
                minimumDeliveryRatio: 0.90,
                maximumFirstFrameLatency: 0.090
            ),
            notes: [
                "Fallback virtual display target while iterating toward UHD.",
                "Use this target when validating frame cadence improvements without reducing refresh rate."
            ]
        )
    }

    public static func allTargets() -> [MDKCaptureOptimizationTarget] {
        captureOnlyValidationTargets + [
            uhdHDR120VirtualDisplay,
            qhdHDR120VirtualDisplay
        ]
    }

    public static func target(identifier: String) -> MDKCaptureOptimizationTarget? {
        allTargets().first { $0.identifier == identifier }
    }
}
