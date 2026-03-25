import Foundation

struct MDKSkyLightDisplayStreamAutotuningSelection: Equatable, Sendable {
    let candidate: MDKSkyLightDisplayStreamTuningCandidate
    let notes: [String]
}

private struct MDKSkyLightDisplayStreamAutotuningCacheKey: Codable, Equatable, Hashable, Sendable {
    let displayID: UInt32
    let processingMode: String
    let outputWidth: Int
    let outputHeight: Int
    let pixelFormat: UInt32
    let targetFrameRate: Int
    let showCursor: Bool
}

private struct MDKSkyLightDisplayStreamAutotuningCacheEntry: Codable, Equatable, Sendable {
    let key: MDKSkyLightDisplayStreamAutotuningCacheKey
    let candidateIdentifier: String
    let effectiveOutputFrameRate: Double
    let cadenceClassification: String
    let updatedAt: Date
}

private struct MDKSkyLightDisplayStreamAutotuningCacheEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let entries: [MDKSkyLightDisplayStreamAutotuningCacheEntry]
}

actor MDKSkyLightDisplayStreamAutotuner {
    static let shared = MDKSkyLightDisplayStreamAutotuner()

    // Bump when the runtime scoring model changes so stale queue/cadence picks
    // do not override a new latency-oriented ranking policy.
    private static let cacheSchemaVersion = 2
    private static let benchmarkSampleDuration: TimeInterval = 0.15

    private var cachedEntries: [MDKSkyLightDisplayStreamAutotuningCacheKey: MDKSkyLightDisplayStreamAutotuningCacheEntry]?

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

        let cacheKey = MDKSkyLightDisplayStreamAutotuningCacheKey(
            displayID: configuration.displayID,
            processingMode: processingMode.rawValue,
            outputWidth: configuration.streamConfiguration.resolvedOutputWidth,
            outputHeight: configuration.streamConfiguration.resolvedOutputHeight,
            pixelFormat: configuration.resolvedCapturePixelFormat,
            targetFrameRate: configuration.targetFrameRate,
            showCursor: configuration.streamConfiguration.resolvedShowCursor
        )

        if let cachedEntry = cachedEntry(for: cacheKey),
           let cachedCandidate = candidates.first(where: { $0.identifier == cachedEntry.candidateIdentifier }) {
            return MDKSkyLightDisplayStreamAutotuningSelection(
                candidate: cachedCandidate,
                notes: [
                    "skyLightAutotuningSource=cache",
                    "skyLightTuningCandidate=\(cachedCandidate.identifier)",
                    "skyLightTuningQueueDepth=\(cachedCandidate.queueDepth)",
                    String(format: "skyLightTuningMinimumFrameTime=%.6f", cachedCandidate.minimumFrameTime),
                    String(format: "skyLightTuningEffectiveOutputFrameRate=%.2f", cachedEntry.effectiveOutputFrameRate),
                    "skyLightTuningCadence=\(cachedEntry.cadenceClassification)"
                ]
            )
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
        storeCachedEntry(
            MDKSkyLightDisplayStreamAutotuningCacheEntry(
                key: cacheKey,
                candidateIdentifier: bestCandidate.identifier,
                effectiveOutputFrameRate: bestResult.effectiveOutputFrameRate,
                cadenceClassification: bestResult.cadenceClassification,
                updatedAt: Date()
            )
        )

        return MDKSkyLightDisplayStreamAutotuningSelection(
            candidate: bestCandidate,
            notes: [
                "skyLightAutotuningSource=benchmarked",
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
            .recommendedCandidates(for: processingMode)
            .map {
                MDKSkyLightDisplayStreamTuningCandidate(
                    identifier: $0.identifier,
                    minimumFrameTime: $0.minimumFrameTime,
                    queueDepth: $0.queueDepth,
                    showCursor: showCursor
                )
            }
    }

    private func cachedEntry(
        for key: MDKSkyLightDisplayStreamAutotuningCacheKey
    ) -> MDKSkyLightDisplayStreamAutotuningCacheEntry? {
        if cachedEntries == nil {
            cachedEntries = Self.loadCache()
        }
        return cachedEntries?[key]
    }

    private func storeCachedEntry(_ entry: MDKSkyLightDisplayStreamAutotuningCacheEntry) {
        if cachedEntries == nil {
            cachedEntries = Self.loadCache()
        }
        cachedEntries?[entry.key] = entry
        Self.saveCache(cachedEntries ?? [:])
    }

    private static func loadCache() -> [MDKSkyLightDisplayStreamAutotuningCacheKey: MDKSkyLightDisplayStreamAutotuningCacheEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: Self.cacheURL),
              let envelope = try? decoder.decode(MDKSkyLightDisplayStreamAutotuningCacheEnvelope.self, from: data),
              envelope.schemaVersion == Self.cacheSchemaVersion else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: envelope.entries.map { ($0.key, $0) })
    }

    private static func saveCache(
        _ entries: [MDKSkyLightDisplayStreamAutotuningCacheKey: MDKSkyLightDisplayStreamAutotuningCacheEntry]
    ) {
        let envelope = MDKSkyLightDisplayStreamAutotuningCacheEnvelope(
            schemaVersion: Self.cacheSchemaVersion,
            entries: entries.values.sorted { lhs, rhs in
                lhs.updatedAt < rhs.updatedAt
            }
        )

        do {
            try FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(envelope)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            return
        }
    }

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "MacDisplayKit", directoryHint: .isDirectory)
            .appending(path: "skylight-processing-autotune.json", directoryHint: .notDirectory)
    }
}
