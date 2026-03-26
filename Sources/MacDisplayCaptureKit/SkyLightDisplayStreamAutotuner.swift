import Foundation

struct MDKSkyLightDisplayStreamAutotuningSelection: Equatable, Sendable {
    let candidate: MDKSkyLightDisplayStreamTuningCandidate
    let notes: [String]
}

actor MDKSkyLightDisplayStreamAutotuner {
    static let shared = MDKSkyLightDisplayStreamAutotuner()

    private static let defaultBenchmarkSampleDuration: TimeInterval = 0.35
    private static let highRefreshBenchmarkSampleDuration: TimeInterval = 0.75
    private static let highRefreshTargetFrameRateFloor = 100
    private static let highRefreshDisplayRefreshRateFloor = 100.0
    private static let highRefreshGuardrailMinimumOutputFrameRate = 48.0

    func resolveSelection(
        for configuration: MDKEncodedCaptureConfiguration
    ) -> MDKSkyLightDisplayStreamAutotuningSelection? {
        guard configuration.resolvedSourceBackend == .skyLightDisplayStream,
              let processingMode = configuration.resolvedSkyLightProcessingMode else {
            return nil
        }

        // Respect explicit queue selections from callers such as the Apollo web UI.
        // Autotuning is only allowed when the caller intentionally leaves the queue
        // profile unset.
        guard configuration.streamConfiguration.queueProfile == nil else {
            return nil
        }

        let candidates = prioritizedCandidates(
            for: configuration,
            processingMode: processingMode
        )
        guard let fallbackCandidate = candidates.first else {
            return nil
        }

        let displayRefreshRate = MDKDisplayRefreshRate(displayID: configuration.displayID)
        if let bootstrapCandidate = Self.highRefreshProductionBootstrapCandidate(
            processingMode: processingMode,
            candidates: candidates,
            targetFrameRate: configuration.targetFrameRate,
            displayRefreshRate: displayRefreshRate
        ) {
            return MDKSkyLightDisplayStreamAutotuningSelection(
                candidate: bootstrapCandidate,
                notes: [
                    "skyLightAutotuningSource=high-refresh-bootstrap",
                    "skyLightTuningCandidate=\(bootstrapCandidate.identifier)",
                    "skyLightTuningQueueDepth=\(bootstrapCandidate.queueDepth)",
                    String(format: "skyLightTuningMinimumFrameTime=%.6f", bootstrapCandidate.minimumFrameTime),
                    String(
                        format: "skyLightDisplayRefreshRate=%@",
                        displayRefreshRate.map { String(format: "%.2f", $0) } ?? "unknown"
                    ),
                    "skyLightBenchmarkSkipped=production-default"
                ]
            )
        }

        let sampleDuration = Self.benchmarkSampleDuration(
            targetFrameRate: configuration.targetFrameRate,
            displayRefreshRate: displayRefreshRate
        )

        let evaluations = candidates.map { candidate in
            let matrixCandidate = MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "\(processingMode.rawValue)/\(candidate.identifier)",
                processingMode: processingMode,
                tuningCandidate: candidate
            )
            do {
                let result = try MDKSkyLightDisplayStreamProcessingBenchmark.run(
                    displayID: configuration.displayID,
                    sampleDuration: sampleDuration,
                    minimumFrameTime: candidate.minimumFrameTime,
                    queueDepth: candidate.queueDepth,
                    showCursor: candidate.showCursor,
                    outputWidth: configuration.streamConfiguration.resolvedOutputWidth == 0 ? nil : configuration.streamConfiguration.resolvedOutputWidth,
                    outputHeight: configuration.streamConfiguration.resolvedOutputHeight == 0 ? nil : configuration.streamConfiguration.resolvedOutputHeight,
                    pixelFormat: configuration.resolvedCapturePixelFormat,
                    targetFrameRate: configuration.targetFrameRate,
                    processingMode: processingMode
                )
                return MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                    candidate: matrixCandidate,
                    result: result,
                    errorDescription: nil
                )
            } catch {
                return MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                    candidate: matrixCandidate,
                    result: nil,
                    errorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }
        let candidateNotes = evaluations.map(describeEvaluation)
        let benchmarkNotes = [
            String(
                format: "skyLightBenchmarkSampleDuration=%.2f",
                sampleDuration
            ),
            String(
                format: "skyLightDisplayRefreshRate=%@",
                displayRefreshRate.map { String(format: "%.2f", $0) } ?? "unknown"
            )
        ]

        if let guardedCandidate = Self.highRefreshGuardrailCandidate(
            for: evaluations,
            targetFrameRate: configuration.targetFrameRate,
            displayRefreshRate: displayRefreshRate
        ) {
            return MDKSkyLightDisplayStreamAutotuningSelection(
                candidate: guardedCandidate,
                notes: candidateNotes + benchmarkNotes + [
                    "skyLightAutotuningSource=high-refresh-guardrail",
                    "skyLightTuningCandidate=\(guardedCandidate.identifier)",
                    "skyLightTuningQueueDepth=\(guardedCandidate.queueDepth)",
                    String(format: "skyLightTuningMinimumFrameTime=%.6f", guardedCandidate.minimumFrameTime),
                    String(
                        format: "skyLightHighRefreshGuardrailMinimumOutputFrameRate=%.2f",
                        Self.highRefreshGuardrailMinimumOutputFrameRate
                    )
                ]
            )
        }

        guard let bestIndex = MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations),
              evaluations.indices.contains(bestIndex),
              let bestResult = evaluations[bestIndex].result else {
            return MDKSkyLightDisplayStreamAutotuningSelection(
                candidate: fallbackCandidate,
                notes: candidateNotes + benchmarkNotes + [
                    "skyLightAutotuningSource=fallback",
                    "skyLightTuningCandidate=\(fallbackCandidate.identifier)",
                    "skyLightTuningQueueDepth=\(fallbackCandidate.queueDepth)",
                    String(format: "skyLightTuningMinimumFrameTime=%.6f", fallbackCandidate.minimumFrameTime),
                    "skyLightTuningCadence=unavailable"
                ]
            )
        }

        let bestCandidate = evaluations[bestIndex].candidate.tuningCandidate

        return MDKSkyLightDisplayStreamAutotuningSelection(
            candidate: bestCandidate,
            notes: candidateNotes + benchmarkNotes + [
                "skyLightAutotuningSource=benchmarked-live",
                "skyLightTuningCandidate=\(bestCandidate.identifier)",
                "skyLightTuningQueueDepth=\(bestCandidate.queueDepth)",
                String(format: "skyLightTuningMinimumFrameTime=%.6f", bestCandidate.minimumFrameTime),
                String(format: "skyLightTuningEffectiveOutputFrameRate=%.2f", bestResult.effectiveOutputFrameRate),
                "skyLightTuningCadence=\(bestResult.cadenceClassification)"
            ]
        )
    }

    static func benchmarkSampleDuration(
        targetFrameRate: Int,
        displayRefreshRate: Double?
    ) -> TimeInterval {
        if isHighRefreshSession(
            targetFrameRate: targetFrameRate,
            displayRefreshRate: displayRefreshRate
        ) {
            return highRefreshBenchmarkSampleDuration
        }

        return defaultBenchmarkSampleDuration
    }

    static func highRefreshGuardrailCandidate(
        for evaluations: [MDKSkyLightDisplayStreamProcessingMatrixEvaluation],
        targetFrameRate: Int,
        displayRefreshRate: Double?
    ) -> MDKSkyLightDisplayStreamTuningCandidate? {
        guard isHighRefreshSession(
            targetFrameRate: targetFrameRate,
            displayRefreshRate: displayRefreshRate
        ) else {
            return nil
        }

        let successfulEvaluations = evaluations.compactMap { evaluation -> (MDKSkyLightDisplayStreamTuningCandidate, MDKSkyLightDisplayStreamProcessingBenchmarkResult)? in
            guard let result = evaluation.result else {
                return nil
            }

            return (evaluation.candidate.tuningCandidate, result)
        }
        guard !successfulEvaluations.isEmpty else {
            return nil
        }

        let hasHealthyCandidate = successfulEvaluations.contains { candidate, result in
            if result.meets120LikeTarget {
                return true
            }

            return result.effectiveOutputFrameRate >= highRefreshGuardrailMinimumOutputFrameRate
        }
        guard !hasHealthyCandidate else {
            return nil
        }

        let guardedEvaluations = successfulEvaluations.filter { candidate, _ in
            candidate.minimumFrameTime == 0 && candidate.queueDepth >= 4
        }
        let preferredEvaluations = guardedEvaluations.isEmpty ? successfulEvaluations : guardedEvaluations

        return preferredEvaluations.max { lhs, rhs in
            highRefreshGuardrailScore(lhs.0, lhs.1) < highRefreshGuardrailScore(rhs.0, rhs.1)
        }?.0
    }

    static func highRefreshProductionBootstrapCandidate(
        processingMode: MDKCaptureBenchmarkProcessingMode,
        candidates: [MDKSkyLightDisplayStreamTuningCandidate],
        targetFrameRate: Int,
        displayRefreshRate: Double?
    ) -> MDKSkyLightDisplayStreamTuningCandidate? {
        guard isHighRefreshSession(
            targetFrameRate: targetFrameRate,
            displayRefreshRate: displayRefreshRate
        ),
        processingMode.videoEncoderCodec != nil else {
            return nil
        }

        return candidates.first {
            $0.identifier == MDKSkyLightDisplayStreamTuningMatrix.request120LikeQueue2Candidate.identifier
        } ?? candidates.first {
            $0.identifier == MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate.identifier
        } ?? candidates.first
    }

    private func describeEvaluation(
        _ evaluation: MDKSkyLightDisplayStreamProcessingMatrixEvaluation
    ) -> String {
        let candidate = evaluation.candidate.tuningCandidate
        if let result = evaluation.result {
            let latencyText = result.maxOutputCallbackLatencyMilliseconds.map {
                String(format: "%.2f", $0)
            } ?? "unknown"
            return String(
                format: "skyLightCandidateResult=%@,fps=%.2f,lat-ms=%@,cadence=%@,queue-depth=%d,min-frame-time=%.6f",
                candidate.identifier,
                result.effectiveOutputFrameRate,
                latencyText,
                result.cadenceClassification,
                candidate.queueDepth,
                candidate.minimumFrameTime
            )
        }

        return "skyLightCandidateResult=\(candidate.identifier),error=\(evaluation.errorDescription ?? "unknown")"
    }

    private func prioritizedCandidates(
        for configuration: MDKEncodedCaptureConfiguration,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) -> [MDKSkyLightDisplayStreamTuningCandidate] {
        let showCursor = configuration.streamConfiguration.resolvedShowCursor
        return MDKSkyLightDisplayStreamTuningAdvisor
            .recommendedCandidates(
                for: processingMode,
                targetFrameRate: configuration.targetFrameRate
            )
            .map {
                MDKSkyLightDisplayStreamTuningCandidate(
                    identifier: $0.identifier,
                    minimumFrameTime: $0.minimumFrameTime,
                    queueDepth: $0.queueDepth,
                    showCursor: showCursor
                )
            }
    }

    private static func isHighRefreshSession(
        targetFrameRate: Int,
        displayRefreshRate: Double?
    ) -> Bool {
        targetFrameRate >= highRefreshTargetFrameRateFloor ||
            (displayRefreshRate ?? 0) >= highRefreshDisplayRefreshRateFloor
    }

    private static func highRefreshGuardrailScore(
        _ candidate: MDKSkyLightDisplayStreamTuningCandidate,
        _ result: MDKSkyLightDisplayStreamProcessingBenchmarkResult
    ) -> (Double, Int, Int, Int) {
        let latencyScore = Int((result.maxOutputCallbackLatencyMilliseconds ?? 1_000).rounded())
        return (
            result.effectiveOutputFrameRate,
            cadenceRank(result.cadenceClassification),
            candidate.minimumFrameTime == 0 ? 1 : 0,
            -latencyScore
        )
    }

    private static func cadenceRank(_ cadenceClassification: String) -> Int {
        switch cadenceClassification {
        case "120hz-like":
            return 4
        case "60hz-like":
            return 3
        case "mixed-or-transitional":
            return 2
        case "coalesced-or-mixed":
            return 1
        default:
            return 0
        }
    }
}
