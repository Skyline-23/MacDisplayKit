import Foundation

@objc
public enum MDKCapturePlanIntent: Int {
    case replaceScreenCaptureKit = 0
    case compareAgainstBaseline = 1
}

@objcMembers
public final class MDKCaptureBackendCandidate: NSObject {
    public let backend: MDKCaptureBackend
    public let available: Bool
    public let reason: String

    public init(backend: MDKCaptureBackend, available: Bool, reason: String) {
        self.backend = backend
        self.available = available
        self.reason = reason
        super.init()
    }
}

@objcMembers
public final class MDKCaptureBenchmarkPlan: NSObject {
    public let target: MDKCaptureOptimizationTarget
    public let display: MDKDisplayDescriptor
    public let intent: MDKCapturePlanIntent
    public let candidates: [MDKCaptureBackendCandidate]

    public init(
        target: MDKCaptureOptimizationTarget,
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        candidates: [MDKCaptureBackendCandidate]
    ) {
        self.target = target
        self.display = display
        self.intent = intent
        self.candidates = candidates
        super.init()
    }

    public var preferredCandidate: MDKCaptureBackendCandidate? {
        candidates.first(where: \.available)
    }
}

@objcMembers
public final class MDKCaptureBackendAvailability: NSObject {
    public let avFoundationAvailable: Bool
    public let cgDisplayStreamAvailable: Bool
    public let screenCaptureKitAvailable: Bool

    public init(
        avFoundationAvailable: Bool,
        cgDisplayStreamAvailable: Bool,
        screenCaptureKitAvailable: Bool
    ) {
        self.avFoundationAvailable = avFoundationAvailable
        self.cgDisplayStreamAvailable = cgDisplayStreamAvailable
        self.screenCaptureKitAvailable = screenCaptureKitAvailable
        super.init()
    }
}

public enum MDKCaptureBenchmarkPlanner {
    public static func plan(
        for display: MDKDisplayDescriptor,
        target: MDKCaptureOptimizationTarget,
        intent: MDKCapturePlanIntent = .replaceScreenCaptureKit,
        availability: MDKCaptureBackendAvailability
    ) -> MDKCaptureBenchmarkPlan {
        let candidates: [MDKCaptureBackendCandidate] = [
            MDKCaptureBackendCandidate(
                backend: .avFoundation,
                available: availability.avFoundationAvailable,
                reason: availability.avFoundationAvailable
                    ? "Legacy AVFoundation capture is available and should be evaluated first as an SCK replacement candidate."
                    : "Legacy AVFoundation capture is not available for this display."
            ),
            MDKCaptureBackendCandidate(
                backend: .cgDisplayStream,
                available: availability.cgDisplayStreamAvailable,
                reason: availability.cgDisplayStreamAvailable
                    ? "CGDisplayStream capture is available and should be benchmarked as another SCK replacement candidate."
                    : "CGDisplayStream backend is not available for this display yet."
            ),
            MDKCaptureBackendCandidate(
                backend: .screenCaptureKit,
                available: availability.screenCaptureKitAvailable,
                reason: availability.screenCaptureKitAvailable
                    ? "ScreenCaptureKit stays in the plan only as a comparison baseline."
                    : "ScreenCaptureKit is not available for this display."
            )
        ]

        return MDKCaptureBenchmarkPlan(
            target: target,
            display: display,
            intent: intent,
            candidates: candidates
        )
    }
}
