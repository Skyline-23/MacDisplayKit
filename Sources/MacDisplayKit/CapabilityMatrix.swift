import Foundation

public enum MDKCapabilityMatrix {
    public static let captureIsStandalone = true
    public static let virtualDisplayIsOptional = true

    public static func optimizationTargets() -> [MDKCaptureOptimizationTarget] {
        MDKCaptureOptimizationTargets.allTargets()
    }
}
