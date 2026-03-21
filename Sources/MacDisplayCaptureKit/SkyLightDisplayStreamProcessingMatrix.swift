import Foundation

public struct MDKSkyLightDisplayStreamProcessingMatrixCandidate: Codable, Equatable, Sendable {
    public let identifier: String
    public let processingMode: MDKCaptureBenchmarkProcessingMode
    public let tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate

    public init(
        identifier: String,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate
    ) {
        self.identifier = identifier
        self.processingMode = processingMode
        self.tuningCandidate = tuningCandidate
    }
}

public struct MDKSkyLightDisplayStreamProcessingMatrixEvaluation: Codable, Equatable, Sendable {
    public let candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate
    public let result: MDKSkyLightDisplayStreamProcessingBenchmarkResult?
    public let errorDescription: String?

    public init(
        candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate,
        result: MDKSkyLightDisplayStreamProcessingBenchmarkResult?,
        errorDescription: String?
    ) {
        self.candidate = candidate
        self.result = result
        self.errorDescription = errorDescription
    }

    public var succeeded: Bool {
        result != nil && errorDescription == nil
    }
}

public struct MDKSkyLightDisplayStreamProcessingMatrixReport: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let sampleDuration: TimeInterval
    public let useMetalStimulus: Bool
    public let evaluations: [MDKSkyLightDisplayStreamProcessingMatrixEvaluation]
    public let bestEvaluationIndex: Int?
    public let notes: [String]

    public init(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        evaluations: [MDKSkyLightDisplayStreamProcessingMatrixEvaluation],
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

    public var bestEvaluation: MDKSkyLightDisplayStreamProcessingMatrixEvaluation? {
        guard let bestEvaluationIndex, evaluations.indices.contains(bestEvaluationIndex) else {
            return nil
        }

        return evaluations[bestEvaluationIndex]
    }
}

public enum MDKSkyLightDisplayStreamProcessingMatrix {
    public static let defaultProcessingModes: [MDKCaptureBenchmarkProcessingMode] = [
        .none,
        .metalBind,
        .metalCopy,
        .videoToolboxEncode
    ]

    public static let defaultCandidates: [MDKSkyLightDisplayStreamProcessingMatrixCandidate] = defaultProcessingModes.flatMap { processingMode in
        MDKSkyLightDisplayStreamTuningMatrix.defaultCandidates.map { tuningCandidate in
            MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "\(processingMode.rawValue)/\(tuningCandidate.identifier)",
                processingMode: processingMode,
                tuningCandidate: tuningCandidate
            )
        }
    }

    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        candidates: [MDKSkyLightDisplayStreamProcessingMatrixCandidate] = defaultCandidates,
        runBenchmark: (UInt32, TimeInterval, Bool, MDKSkyLightDisplayStreamProcessingMatrixCandidate) throws -> MDKSkyLightDisplayStreamProcessingBenchmarkResult
    ) -> MDKSkyLightDisplayStreamProcessingMatrixReport {
        let evaluations = candidates.map { candidate in
            do {
                return MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                    candidate: candidate,
                    result: try runBenchmark(displayID, sampleDuration, useMetalStimulus, candidate),
                    errorDescription: nil
                )
            } catch {
                return MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                    candidate: candidate,
                    result: nil,
                    errorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }

        let bestIndex = bestEvaluationIndex(for: evaluations)
        var notes = [
            "Evaluates raw SkyLight SLDisplayStream processing modes against a fixed tuning candidate set.",
            "Each candidate runs in a fresh child process to avoid in-process stream state contaminating later measurements.",
            "The none processing mode is kept as a raw control and is not eligible for default winner selection.",
            "Ranking order: meets120LikeTarget, cadence classification, processed frame rate, processed frame ratio, then complete-frame count."
        ]
        if let bestIndex,
           evaluations.indices.contains(bestIndex),
           let bestResult = evaluations[bestIndex].result {
            let bestCandidate = evaluations[bestIndex].candidate
            notes.append(
                "bestCandidate=\(bestCandidate.processingMode.rawValue)/\(bestCandidate.tuningCandidate.identifier) processedFrameRate=\(String(format: "%.2f", bestResult.processedFrameRate)) cadence=\(bestResult.cadenceClassification)"
            )
        } else {
            notes.append("No successful processing benchmark candidates were available.")
        }

        return MDKSkyLightDisplayStreamProcessingMatrixReport(
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: useMetalStimulus,
            evaluations: evaluations,
            bestEvaluationIndex: bestIndex,
            notes: notes
        )
    }

    public static func bestEvaluationIndex(
        for evaluations: [MDKSkyLightDisplayStreamProcessingMatrixEvaluation]
    ) -> Int? {
        evaluations.enumerated()
            .filter { evaluation in
                evaluation.element.succeeded &&
                evaluation.element.candidate.processingMode != .none
            }
            .max { lhs, rhs in
                guard let lhsResult = lhs.element.result, let rhsResult = rhs.element.result else {
                    return false
                }
                return score(lhsResult) < score(rhsResult)
            }?
            .offset
    }

    private static func score(
        _ result: MDKSkyLightDisplayStreamProcessingBenchmarkResult
    ) -> (Int, Int, Double, Double, UInt64) {
        (
            result.meets120LikeTarget ? 1 : 0,
            cadenceRank(result.cadenceClassification),
            result.processedFrameRate,
            result.processedFrameRatio,
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
