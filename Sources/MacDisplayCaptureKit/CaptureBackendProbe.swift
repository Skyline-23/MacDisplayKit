import Foundation
import MacDisplayKitObjCShim

@objcMembers
public final class MDKCaptureBackendProbe: NSObject {
    public static func availability(
        for display: MDKDisplayDescriptor,
        target: MDKCaptureOptimizationTarget
    ) -> MDKCaptureBackendAvailability {
        let requestedFrameRate = max(target.frameRate, 1)
        let screenCaptureAccessAuthorized = MDKShimScreenCaptureAccessAuthorized()

        return MDKCaptureBackendAvailability(
            screenCaptureAccessAuthorized: screenCaptureAccessAuthorized,
            avFoundationAvailable: MDKShimVideoAVFoundationAvailableForDisplay(
                UInt(display.id),
                requestedFrameRate
            ),
            cgDisplayStreamAvailable: MDKShimVideoCGDisplayStreamAvailableForDisplay(
                UInt(display.id)
            )
        )
    }
}
