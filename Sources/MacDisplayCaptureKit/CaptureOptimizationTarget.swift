import Foundation

@objc
public enum MDKCaptureScenarioTopology: Int {
    case captureOnly = 0
    case virtualDisplay = 1
}

@objcMembers
public final class MDKCaptureOptimizationTarget: NSObject, NSCopying {
    public let name: String
    public let topology: MDKCaptureScenarioTopology
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let dynamicRangeMode: MDKDynamicRangeMode
    public let recommendedBackend: MDKCaptureBackend
    public let notes: [String]

    public init(
        name: String,
        topology: MDKCaptureScenarioTopology,
        width: Int,
        height: Int,
        frameRate: Int,
        dynamicRangeMode: MDKDynamicRangeMode,
        recommendedBackend: MDKCaptureBackend,
        notes: [String]
    ) {
        self.name = name
        self.topology = topology
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.dynamicRangeMode = dynamicRangeMode
        self.recommendedBackend = recommendedBackend
        self.notes = notes
        super.init()
    }

    public var requiresVirtualDisplay: Bool {
        topology == .virtualDisplay
    }

    public func makeConfiguration(displayID: UInt32, pixelFormat: UInt32) -> MDKCaptureConfiguration {
        MDKCaptureConfiguration(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat,
            backend: recommendedBackend,
            dynamicRangeMode: dynamicRangeMode
        )
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        MDKCaptureOptimizationTarget(
            name: name,
            topology: topology,
            width: width,
            height: height,
            frameRate: frameRate,
            dynamicRangeMode: dynamicRangeMode,
            recommendedBackend: recommendedBackend,
            notes: notes
        )
    }
}

public enum MDKCaptureOptimizationTargets {
    public static var uhdHDR120CaptureOnly: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            name: "UHD HDR 120 Capture Only",
            topology: .captureOnly,
            width: 3840,
            height: 2160,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .screenCaptureKit,
            notes: [
                "Primary performance target for 4K HDR 120 capture.",
                "Use this baseline to evaluate capture backend regressions before transport tuning."
            ]
        )
    }

    public static var uhdHDR120VirtualDisplay: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            name: "UHD HDR 120 Virtual Display",
            topology: .virtualDisplay,
            width: 3840,
            height: 2160,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .screenCaptureKit,
            notes: [
                "Stretch goal for virtual display capture at UHD HDR 120.",
                "Useful for measuring the combined cost of display synthesis and frame acquisition."
            ]
        )
    }

    public static var qhdHDR120VirtualDisplay: MDKCaptureOptimizationTarget {
        MDKCaptureOptimizationTarget(
            name: "QHD HDR 120 Virtual Display",
            topology: .virtualDisplay,
            width: 2560,
            height: 1440,
            frameRate: 120,
            dynamicRangeMode: .hdrCanonical,
            recommendedBackend: .screenCaptureKit,
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
}
