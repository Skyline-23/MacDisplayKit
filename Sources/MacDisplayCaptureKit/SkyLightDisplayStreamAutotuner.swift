import Foundation

struct MDKSkyLightDisplayStreamAutotuningSelection: Equatable, Sendable {
    let candidate: MDKSkyLightDisplayStreamTuningCandidate
    let notes: [String]
}

actor MDKSkyLightDisplayStreamAutotuner {
    static let shared = MDKSkyLightDisplayStreamAutotuner()

    private static let benchmarkSampleDuration: TimeInterval = 0.35

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

        let evaluations = candidates.map { candidate in
            let matrixCandidate = MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "\(processingMode.rawValue)/\(candidate.identifier)",
                processingMode: processingMode,
                tuningCandidate: candidate
            )
            do {
                let result = try MDKSkyLightDisplayStreamProcessingBenchmark.run(
                    displayID: configuration.displayID,
                    sampleDuration: Self.benchmarkSampleDuration,
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

        guard let bestIndex = MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations),
              evaluations.indices.contains(bestIndex),
              let bestResult = evaluations[bestIndex].result else {
            return MDKSkyLightDisplayStreamAutotuningSelection(
                candidate: fallbackCandidate,
                notes: [
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
            notes: [
                "skyLightAutotuningSource=benchmarked-live",
                "skyLightTuningCandidate=\(bestCandidate.identifier)",
                "skyLightTuningQueueDepth=\(bestCandidate.queueDepth)",
                String(format: "skyLightTuningMinimumFrameTime=%.6f", bestCandidate.minimumFrameTime),
                String(format: "skyLightTuningEffectiveOutputFrameRate=%.2f", bestResult.effectiveOutputFrameRate),
                "skyLightTuningCadence=\(bestResult.cadenceClassification)"
            ]
        )
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
}
