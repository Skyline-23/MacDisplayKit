import Foundation

@objc
public enum MDKCapturePlanIntent: Int {
    case validateDefaultBackend = 0
    case compareBackends = 1
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
    public let screenCaptureAccessAuthorized: Bool
    public let candidates: [MDKCaptureBackendCandidate]

    public init(
        target: MDKCaptureOptimizationTarget,
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        screenCaptureAccessAuthorized: Bool,
        candidates: [MDKCaptureBackendCandidate]
    ) {
        self.target = target
        self.display = display
        self.intent = intent
        self.screenCaptureAccessAuthorized = screenCaptureAccessAuthorized
        self.candidates = candidates
        super.init()
    }

    public var preferredCandidate: MDKCaptureBackendCandidate? {
        candidates.first(where: \.available)
    }
}

@objcMembers
public final class MDKCaptureBackendAvailability: NSObject {
    public let screenCaptureAccessAuthorized: Bool
    public let avFoundationAvailable: Bool
    public let cgDisplayStreamAvailable: Bool

    public init(
        screenCaptureAccessAuthorized: Bool,
        avFoundationAvailable: Bool,
        cgDisplayStreamAvailable: Bool
    ) {
        self.screenCaptureAccessAuthorized = screenCaptureAccessAuthorized
        self.avFoundationAvailable = avFoundationAvailable
        self.cgDisplayStreamAvailable = cgDisplayStreamAvailable
        super.init()
    }
}

public enum MDKCaptureBenchmarkPlanner {
    public static func plan(
        for display: MDKDisplayDescriptor,
        target: MDKCaptureOptimizationTarget,
        intent: MDKCapturePlanIntent = .validateDefaultBackend,
        availability: MDKCaptureBackendAvailability
    ) -> MDKCaptureBenchmarkPlan {
        let screenCapturePermissionReason = "Screen Recording permission is not granted for this host process."
        func availableReason(for backend: MDKCaptureBackend) -> String {
            if backend == target.recommendedBackend {
                return "\(backend.displayName) capture is available and should be benchmarked first as the default native capture backend."
            }

            return "\(backend.displayName) capture is available and should be benchmarked as an alternate native capture backend."
        }

        let candidatesByBackend: [MDKCaptureBackend: MDKCaptureBackendCandidate] = [
            .avFoundation: MDKCaptureBackendCandidate(
                backend: .avFoundation,
                available: availability.screenCaptureAccessAuthorized && availability.avFoundationAvailable,
                reason: !availability.screenCaptureAccessAuthorized
                    ? screenCapturePermissionReason
                    : availability.avFoundationAvailable
                    ? availableReason(for: .avFoundation)
                    : "Legacy AVFoundation capture is not available for this display."
            ),
            .cgDisplayStream: MDKCaptureBackendCandidate(
                backend: .cgDisplayStream,
                available: availability.screenCaptureAccessAuthorized && availability.cgDisplayStreamAvailable,
                reason: !availability.screenCaptureAccessAuthorized
                    ? screenCapturePermissionReason
                    : availability.cgDisplayStreamAvailable
                    ? availableReason(for: .cgDisplayStream)
                    : "CGDisplayStream backend is not available for this display yet."
            ),
        ]

        let orderedBackends = [
            target.recommendedBackend,
            MDKCaptureBackend.avFoundation,
            MDKCaptureBackend.cgDisplayStream,
        ]

        var seenBackends = Set<MDKCaptureBackend>()
        var candidates: [MDKCaptureBackendCandidate] = []
        for backend in orderedBackends {
            guard seenBackends.insert(backend).inserted else {
                continue
            }
            if let candidate = candidatesByBackend[backend] {
                candidates.append(candidate)
            }
        }

        return MDKCaptureBenchmarkPlan(
            target: target,
            display: display,
            intent: intent,
            screenCaptureAccessAuthorized: availability.screenCaptureAccessAuthorized,
            candidates: candidates
        )
    }
}
