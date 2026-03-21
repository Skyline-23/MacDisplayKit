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
    public static let defaultCandidates: [MDKSkyLightDisplayStreamTuningCandidate] = [
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "baseline-q3",
            minimumFrameTime: 0,
            queueDepth: 3,
            showCursor: false
        ),
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "baseline-q8",
            minimumFrameTime: 0,
            queueDepth: 8,
            showCursor: false
        ),
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "min-frame-240hz-q3",
            minimumFrameTime: 1.0 / 240.0,
            queueDepth: 3,
            showCursor: false
        ),
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "min-frame-240hz-q8",
            minimumFrameTime: 1.0 / 240.0,
            queueDepth: 8,
            showCursor: false
        ),
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "legacy-120hz-request",
            minimumFrameTime: 1.0 / 120.0,
            queueDepth: 8,
            showCursor: false
        ),
        MDKSkyLightDisplayStreamTuningCandidate(
            identifier: "legacy-120hz-q3",
            minimumFrameTime: 1.0 / 120.0,
            queueDepth: 3,
            showCursor: false
        )
    ]

    public static func bestEvaluationIndex(
        for evaluations: [MDKSkyLightDisplayStreamTuningEvaluation]
    ) -> Int? {
        evaluations.enumerated().max { lhs, rhs in
            score(lhs.element.result) < score(rhs.element.result)
        }?.offset
    }

    private static func score(
        _ result: MDKSkyLightDisplayStreamBenchmarkResult
    ) -> (Int, Int, Double, UInt64) {
        (
            result.meetsRealtimeFloor ? 1 : 0,
            cadenceRank(result.cadenceClassification),
            result.observedFrameRate,
            result.completeFrameCount
        )
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
