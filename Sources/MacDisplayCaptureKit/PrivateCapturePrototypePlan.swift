import Foundation

public enum MDKPrivateCaptureEntryPoint: String, Codable, Equatable, Sendable {
    case displayStreamProxying = "sls-display-stream-proxying"
    case displayIOSurfaceProxying = "sls-display-iosurface-proxying"
    case displayIOSurfaceWithOptions = "cgshw-display-iosurface-with-options"
    case displayIOSurface = "cgshw-display-iosurface"
    case desktopCapture = "cgshw-desktop"
    case unavailable = "unavailable"

    public var displayName: String {
        switch self {
        case .displayStreamProxying:
            return "SLSDisplayStreamCreateProxying"
        case .displayIOSurfaceProxying:
            return "SLSHWCaptureDisplayIntoIOSurfaceProxying"
        case .displayIOSurfaceWithOptions:
            return "CGSHWCaptureDisplayIntoIOSurfaceWithOptions"
        case .displayIOSurface:
            return "CGSHWCaptureDisplayIntoIOSurface"
        case .desktopCapture:
            return "CGSHWCaptureDesktop"
        case .unavailable:
            return "Unavailable"
        }
    }
}

public struct MDKPrivateCapturePrototypePlan: Codable, Equatable, Sendable {
    public let capabilities: MDKPrivateCaptureCapabilities
    public let recommendedEntryPoint: MDKPrivateCaptureEntryPoint
    public let readyForIOSurfacePrototype: Bool
    public let recommendedNotes: [String]

    public init(
        capabilities: MDKPrivateCaptureCapabilities,
        recommendedEntryPoint: MDKPrivateCaptureEntryPoint,
        readyForIOSurfacePrototype: Bool,
        recommendedNotes: [String]
    ) {
        self.capabilities = capabilities
        self.recommendedEntryPoint = recommendedEntryPoint
        self.readyForIOSurfacePrototype = readyForIOSurfacePrototype
        self.recommendedNotes = recommendedNotes
    }
}

public enum MDKPrivateCapturePrototypePlanner {
    public static func current() -> MDKPrivateCapturePrototypePlan {
        plan(for: MDKPrivateCaptureCapabilityProbe.current())
    }

    public static func plan(
        for capabilities: MDKPrivateCaptureCapabilities
    ) -> MDKPrivateCapturePrototypePlan {
        if capabilities.displayStreamProxyAvailable {
            return MDKPrivateCapturePrototypePlan(
                capabilities: capabilities,
                recommendedEntryPoint: .displayStreamProxying,
                readyForIOSurfacePrototype: false,
                recommendedNotes: [
                    "Prefer the ScreenCaptureKit display-stream proxy create path because it is the strongest candidate for a reusable hardware-backed stream session.",
                    "Start with a create-only probe that watches the supplied mach port for activity before attempting any repeated capture loop."
                ]
            )
        }

        if capabilities.displayIOSurfaceProxyCaptureAvailable {
            return MDKPrivateCapturePrototypePlan(
                capabilities: capabilities,
                recommendedEntryPoint: .displayIOSurfaceProxying,
                readyForIOSurfacePrototype: true,
                recommendedNotes: [
                    "Prefer the ScreenCaptureKit proxying entry point because it bypasses the SkyLight wrapper and should avoid per-frame mach-port churn.",
                    capabilities.extendedRangeOptionAvailable
                        ? "Keep the extended-range option bit enabled during the first proxy benchmark so HDR behavior stays comparable to the wrapper path."
                        : "Treat HDR as unresolved until an explicit extended-range hint becomes available."
                ]
            )
        }

        if capabilities.displayIOSurfaceCaptureWithOptionsAvailable {
            return MDKPrivateCapturePrototypePlan(
                capabilities: capabilities,
                recommendedEntryPoint: .displayIOSurfaceWithOptions,
                readyForIOSurfacePrototype: true,
                recommendedNotes: [
                    "Prefer the IOSurface path with options because it is the strongest candidate for direct-to-Metal capture.",
                    capabilities.extendedRangeOptionAvailable
                        ? "kSLSCaptureExtendedRange is available and should be tested as the first HDR hint."
                        : "Extended-range capture hints are not exported, so the first probe should stay SDR-safe."
                ]
            )
        }

        if capabilities.displayIOSurfaceCaptureAvailable {
            return MDKPrivateCapturePrototypePlan(
                capabilities: capabilities,
                recommendedEntryPoint: .displayIOSurface,
                readyForIOSurfacePrototype: true,
                recommendedNotes: [
                    "Fallback to the plain IOSurface path because the options-bearing variant is unavailable.",
                    "Treat HDR as unresolved until an explicit extended-range hint becomes available."
                ]
            )
        }

        if capabilities.desktopCaptureAvailable {
            return MDKPrivateCapturePrototypePlan(
                capabilities: capabilities,
                recommendedEntryPoint: .desktopCapture,
                readyForIOSurfacePrototype: false,
                recommendedNotes: [
                    "Only the desktop capture path is exported, so use it for semantic probing rather than sustained video capture.",
                    "Keep the host experiment isolated because this path is likely image-oriented rather than stream-oriented."
                ]
            )
        }

        return MDKPrivateCapturePrototypePlan(
            capabilities: capabilities,
            recommendedEntryPoint: .unavailable,
            readyForIOSurfacePrototype: false,
            recommendedNotes: [
                "No private hardware capture symbols are currently exported on this system.",
                "Stay on public capture backends until a lower-level surface is discovered."
            ]
        )
    }
}
