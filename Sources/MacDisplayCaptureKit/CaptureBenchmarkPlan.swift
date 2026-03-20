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

    public init(
        avFoundationAvailable: Bool,
        cgDisplayStreamAvailable: Bool
    ) {
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
        let candidatesByBackend: [MDKCaptureBackend: MDKCaptureBackendCandidate] = [
            .avFoundation: MDKCaptureBackendCandidate(
                backend: .avFoundation,
                available: availability.avFoundationAvailable,
                reason: availability.avFoundationAvailable
                    ? "Legacy AVFoundation capture is available and remains the lowest-risk native fallback."
                    : "Legacy AVFoundation capture is not available for this display."
            ),
            .cgDisplayStream: MDKCaptureBackendCandidate(
                backend: .cgDisplayStream,
                available: availability.cgDisplayStreamAvailable,
                reason: availability.cgDisplayStreamAvailable
                    ? "CGDisplayStream capture is available and should be benchmarked first as the primary native capture backend."
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
            candidates: candidates
        )
    }
}
