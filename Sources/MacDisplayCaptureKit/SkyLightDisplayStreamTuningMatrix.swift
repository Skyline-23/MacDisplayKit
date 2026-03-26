import Foundation

public struct MDKSkyLightDisplayStreamTuningCandidate: Codable, Equatable, Sendable {
    public let identifier: String
    public let minimumFrameTime: Double
    public let queueDepth: Int
    public let showCursor: Bool

    public init(
        identifier: String,
        minimumFrameTime: Double,
        queueDepth: Int,
        showCursor: Bool
    ) {
        self.identifier = identifier
        self.minimumFrameTime = minimumFrameTime
        self.queueDepth = queueDepth
        self.showCursor = showCursor
    }
}

public struct MDKSkyLightDisplayStreamTuningEvaluation: Codable, Equatable, Sendable {
    public let candidate: MDKSkyLightDisplayStreamTuningCandidate
    public let result: MDKSkyLightDisplayStreamBenchmarkResult

    public init(
        candidate: MDKSkyLightDisplayStreamTuningCandidate,
        result: MDKSkyLightDisplayStreamBenchmarkResult
    ) {
        self.candidate = candidate
        self.result = result
    }
}

public struct MDKSkyLightDisplayStreamTuningMatrixReport: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let sampleDuration: TimeInterval
    public let useMetalStimulus: Bool
    public let evaluations: [MDKSkyLightDisplayStreamTuningEvaluation]
    public let bestEvaluationIndex: Int?
    public let notes: [String]

    public init(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        evaluations: [MDKSkyLightDisplayStreamTuningEvaluation],
        bestEvaluationIndex: Int?,
        notes: [String]
    ) {
        self.displayID = displayID
        self.sampleDuration = sampleDuration
        self.useMetalStimulus = useMetalStimulus
        self.evaluations = evaluations
        self.bestEvaluationIndex = bestEvaluationIndex
        self.notes = notes
    }

    public var bestEvaluation: MDKSkyLightDisplayStreamTuningEvaluation? {
        guard let bestEvaluationIndex, evaluations.indices.contains(bestEvaluationIndex) else {
            return nil
        }

        return evaluations[bestEvaluationIndex]
    }
}

public enum MDKSkyLightDisplayStreamTuningMatrix {
    public static let baselineQueue1Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "baseline-q1",
        minimumFrameTime: 0,
        queueDepth: 1,
        showCursor: false
    )

    public static let baselineQueue2Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "baseline-q2",
        minimumFrameTime: 0,
        queueDepth: 2,
        showCursor: false
    )

    public static let baselineQueue3Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "baseline-q3",
        minimumFrameTime: 0,
        queueDepth: 3,
        showCursor: false
    )

    public static let baselineQueue4Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "baseline-q4",
        minimumFrameTime: 0,
        queueDepth: 4,
        showCursor: false
    )

    public static let baselineQueue8Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "baseline-q8",
        minimumFrameTime: 0,
        queueDepth: 8,
        showCursor: false
    )

    public static let request120LikeQueue2Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "min-frame-240hz-q2",
        minimumFrameTime: 1.0 / 240.0,
        queueDepth: 2,
        showCursor: false
    )

    public static let request120LikeCandidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "min-frame-240hz-q1",
        minimumFrameTime: 1.0 / 240.0,
        queueDepth: 1,
        showCursor: false
    )

    public static let request120LikeQueue8Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "min-frame-240hz-q8",
        minimumFrameTime: 1.0 / 240.0,
        queueDepth: 8,
        showCursor: false
    )

    public static let legacy120HzRequestCandidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "legacy-120hz-request",
        minimumFrameTime: 1.0 / 120.0,
        queueDepth: 8,
        showCursor: false
    )

    public static let legacy120HzQueue3Candidate = MDKSkyLightDisplayStreamTuningCandidate(
        identifier: "legacy-120hz-q3",
        minimumFrameTime: 1.0 / 120.0,
        queueDepth: 3,
        showCursor: false
    )

    public static let defaultCandidates: [MDKSkyLightDisplayStreamTuningCandidate] = [
        baselineQueue3Candidate,
        baselineQueue8Candidate,
        request120LikeCandidate,
        request120LikeQueue8Candidate,
        legacy120HzRequestCandidate,
        legacy120HzQueue3Candidate
    ]

    public static func bestEvaluationIndex(
        for evaluations: [MDKSkyLightDisplayStreamTuningEvaluation]
    ) -> Int? {
        evaluations.enumerated().max { lhs, rhs in
            isScore(score(lhs.element.result), lessThan: score(rhs.element.result))
        }?.offset
    }

    private static func score(
        _ result: MDKSkyLightDisplayStreamBenchmarkResult
    ) -> (Int, Int, Int, Double, UInt64) {
        (
            result.meetsRealtimeFloor ? 1 : 0,
            -stallPenalty(result),
            cadenceRank(result.cadenceClassification),
            result.observedFrameRate,
            result.completeFrameCount
        )
    }

    private static func stallPenalty(_ result: MDKSkyLightDisplayStreamBenchmarkResult) -> Int {
        (result.stallCountOver100Milliseconds * 1_000_000) +
            (result.stallCountOver33Milliseconds * 1_000) +
            result.stallCountOver16Milliseconds
    }

    private static func isScore(
        _ lhs: (Int, Int, Int, Double, UInt64),
        lessThan rhs: (Int, Int, Int, Double, UInt64)
    ) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
        if lhs.3 != rhs.3 { return lhs.3 < rhs.3 }
        return lhs.4 < rhs.4
    }

    private static func cadenceRank(_ cadenceClassification: String) -> Int {
        switch cadenceClassification {
        case "120hz-like":
            return 4
        case "coalesced-or-mixed":
            return 3
        case "mixed-or-transitional":
            return 2
        case "60hz-like":
            return 1
        default:
            return 0
        }
    }
}

public enum MDKSkyLightDisplayStreamTuningAdvisor {
    public static func recommendedCandidates(
        for processingMode: MDKCaptureBenchmarkProcessingMode,
        targetFrameRate: Int? = nil
    ) -> [MDKSkyLightDisplayStreamTuningCandidate] {
        let prefersHighRefreshCandidates = (targetFrameRate ?? 0) >= 100

        switch processingMode {
        case .videoToolboxEncodeProResProxyExperimental:
            return [
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue1Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue3Candidate
            ]
        case .videoToolboxEncode,
             .videoToolboxEncodeDownscale2x,
             .videoToolboxEncodeH264,
             .videoToolboxEncodeH264Downscale2x:
            var candidates = [
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.request120LikeQueue2Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue3Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue1Candidate,
                MDKSkyLightDisplayStreamTuningMatrix.request120LikeCandidate,
                MDKSkyLightDisplayStreamTuningMatrix.baselineQueue4Candidate
            ]
            if prefersHighRefreshCandidates {
                candidates.append(contentsOf: [
                    MDKSkyLightDisplayStreamTuningMatrix.baselineQueue8Candidate,
                    MDKSkyLightDisplayStreamTuningMatrix.request120LikeQueue8Candidate,
                    MDKSkyLightDisplayStreamTuningMatrix.legacy120HzRequestCandidate,
                    MDKSkyLightDisplayStreamTuningMatrix.legacy120HzQueue3Candidate
                ])
            }
            return candidates
        case .none, .metalBind, .metalCopy:
            return MDKSkyLightDisplayStreamTuningMatrix.defaultCandidates
        }
    }
}
