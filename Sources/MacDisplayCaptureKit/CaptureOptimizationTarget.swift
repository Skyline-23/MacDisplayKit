import Foundation

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

    public func makeConfiguration(
        displayID: UInt32,
        pixelFormat: UInt32,
        backend: MDKCaptureBackend? = nil
    ) -> MDKCaptureConfiguration {
        MDKCaptureConfiguration(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat,
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
            recommendedBackend: .cgDisplayStream,
            acceptanceThresholds: MDKCaptureBenchmarkThresholds(
                minimumObservedFrameRateRatio: 0.90,
                minimumDeliveryRatio: 0.92,
                maximumFirstFrameLatency: 0.080
            ),
            notes: [
                "Primary performance target for 4K HDR 120 capture.",
                "Prefer CGDisplayStream first when validating the primary native capture backend."
            ]
        )
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
        [
            uhdHDR120CaptureOnly,
            uhdHDR120VirtualDisplay,
            qhdHDR120VirtualDisplay
        ]
    }

    public static func target(identifier: String) -> MDKCaptureOptimizationTarget? {
        allTargets().first { $0.identifier == identifier }
    }
}
