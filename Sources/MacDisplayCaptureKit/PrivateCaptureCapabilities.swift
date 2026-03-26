import Foundation
import MacDisplayKitObjCShim

public struct MDKPrivateCaptureCapabilities: Codable, Equatable, Sendable {
    public let desktopCaptureAvailable: Bool
    public let displayIOSurfaceCaptureAvailable: Bool
    public let displayIOSurfaceCaptureWithOptionsAvailable: Bool
    public let displayIOSurfaceProxyCaptureAvailable: Bool
    public let displayStreamProxyAvailable: Bool
    public let rawSkyLightDisplayStreamAvailable: Bool
    public let extendedRangeOptionAvailable: Bool

    public init(
        desktopCaptureAvailable: Bool,
        displayIOSurfaceCaptureAvailable: Bool,
        displayIOSurfaceCaptureWithOptionsAvailable: Bool,
        displayIOSurfaceProxyCaptureAvailable: Bool,
        displayStreamProxyAvailable: Bool,
        rawSkyLightDisplayStreamAvailable: Bool = false,
        extendedRangeOptionAvailable: Bool
    ) {
        self.desktopCaptureAvailable = desktopCaptureAvailable
        self.displayIOSurfaceCaptureAvailable = displayIOSurfaceCaptureAvailable
        self.displayIOSurfaceCaptureWithOptionsAvailable = displayIOSurfaceCaptureWithOptionsAvailable
        self.displayIOSurfaceProxyCaptureAvailable = displayIOSurfaceProxyCaptureAvailable
        self.displayStreamProxyAvailable = displayStreamProxyAvailable
        self.rawSkyLightDisplayStreamAvailable = rawSkyLightDisplayStreamAvailable
        self.extendedRangeOptionAvailable = extendedRangeOptionAvailable
    }

    public var hasAnyHardwareCaptureSurface: Bool {
        desktopCaptureAvailable ||
            displayIOSurfaceCaptureAvailable ||
            displayIOSurfaceCaptureWithOptionsAvailable ||
            displayIOSurfaceProxyCaptureAvailable ||
            displayStreamProxyAvailable ||
            rawSkyLightDisplayStreamAvailable
    }

    public var supportsIOSurfaceDisplayCapture: Bool {
        displayIOSurfaceCaptureAvailable ||
            displayIOSurfaceCaptureWithOptionsAvailable ||
            displayIOSurfaceProxyCaptureAvailable
    }

    public var supportsHDRHardwareCaptureHints: Bool {
        supportsIOSurfaceDisplayCapture && extendedRangeOptionAvailable
    }
}

public enum MDKPrivateCaptureCapabilityProbe {
    public static func current() -> MDKPrivateCaptureCapabilities {
        MDKPrivateCaptureCapabilities(
            desktopCaptureAvailable: MDKShimVideoPrivateDesktopCaptureAvailable(),
            displayIOSurfaceCaptureAvailable: MDKShimVideoPrivateDisplayIOSurfaceCaptureAvailable(),
            displayIOSurfaceCaptureWithOptionsAvailable: MDKShimVideoPrivateDisplayIOSurfaceCaptureWithOptionsAvailable(),
            displayIOSurfaceProxyCaptureAvailable: MDKShimVideoPrivateDisplayIOSurfaceProxyCaptureAvailable(),
            displayStreamProxyAvailable: MDKShimVideoPrivateDisplayStreamProxyAvailable(),
            rawSkyLightDisplayStreamAvailable: MDKShimVideoRawSkyLightDisplayStreamAvailable(),
            extendedRangeOptionAvailable: MDKShimVideoPrivateCaptureExtendedRangeOptionAvailable()
        )
    }
}
