import Foundation
import MacDisplayCaptureKit

public enum MDKCapabilityMatrix {
    public static let captureIsStandalone = true
    public static let virtualDisplayIsOptional = true

    public static func optimizationTargets() -> [MDKCaptureOptimizationTarget] {
        MDKCaptureOptimizationTargets.allTargets()
    }

    public static func privateCaptureCapabilities() -> MDKPrivateCaptureCapabilities {
        MDKPrivateCaptureCapabilityProbe.current()
    }

    public static func privateCapturePrototypePlan() -> MDKPrivateCapturePrototypePlan {
        MDKPrivateCapturePrototypePlanner.current()
    }
}
