import Foundation
import MacDisplayKit
import MacDisplayCaptureKit
import CoreGraphics

final class MDKHostBenchmarkController {
    static let benchmarkWarmupDuration: TimeInterval = 1.0
    static let benchmarkSampleDuration: TimeInterval = 3.0

    func availableDisplays() -> [MDKDisplayDescriptor] {
        MDKCaptureDiscovery.displays()
    }

    func availableTargets() -> [MDKCaptureOptimizationTarget] {
        MDKCapabilityMatrix.optimizationTargets()
    }

    func display(id: UInt32) -> MDKDisplayDescriptor? {
        availableDisplays().first { $0.id == id }
    }

    func defaultDisplay() -> MDKDisplayDescriptor? {
        let displays = availableDisplays()
        let mainDisplayID = UInt32(CGMainDisplayID())
        if let mainDisplay = displays.first(where: { $0.id == mainDisplayID }) {
            return mainDisplay
        }

        return displays.first
    }

    func target(identifier: String) -> MDKCaptureOptimizationTarget? {
        MDKCaptureOptimizationTargets.target(identifier: identifier)
    }

    func runBenchmark(
        display: MDKDisplayDescriptor,
        target: MDKCaptureOptimizationTarget,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) -> MDKCaptureBenchmarkSuiteResult {
        let availability = MDKCaptureBackendProbe.availability(for: display, target: target)
        let plan = MDKCaptureBenchmarkPlanner.plan(
            for: display,
            target: target,
            intent: intent,
            availability: availability
        )

        return MDKCaptureBenchmarkSuiteRunner.run(
            plan: plan,
            processingMode: processingMode,
            pixelFormat: target.benchmarkPixelFormat,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }

    func runCaptureOnlyValidationMatrix(
        display: MDKDisplayDescriptor,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) -> MDKCaptureBenchmarkMatrixResult {
        MDKCaptureBenchmarkMatrixRunner.runCaptureOnlyValidationMatrix(
            display: display,
            intent: intent,
            processingMode: processingMode,
            warmupDuration: Self.benchmarkWarmupDuration,
            sampleDuration: Self.benchmarkSampleDuration
        )
    }

    func privateCapturePrototypePlan() -> MDKPrivateCapturePrototypePlan {
        MDKCapabilityMatrix.privateCapturePrototypePlan()
    }

    func probePrivateCaptureSingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.captureSingleFrame(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange
        )
    }

    func probePrivateProxyCaptureSingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.captureProxySingleFrame(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange
        )
    }

    func probePrivateDisplayStream(
        displayID: UInt32
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.createDisplayStream(displayID: displayID)
    }

    func probePrivateDisplayStream(
        displayID: UInt32,
        configuration: MDKPrivateDisplayStreamProbeConfiguration
    ) throws -> MDKPrivateCaptureProbeResult {
        try MDKPrivateCapturePrototypeProbe.createDisplayStream(
            displayID: displayID,
            configuration: configuration
        )
    }

    func probePrivateDisplayStreamMatrix(
        displayID: UInt32
    ) throws -> [MDKPrivateCaptureProbeResult] {
        try MDKPrivateCapturePrototypeProbe.createDisplayStreamMatrix(displayID: displayID)
    }

    func benchmarkPrivateCapture(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        try MDKPrivateCapturePrototypeBenchmark.run(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange,
            sampleDuration: sampleDuration
        )
    }

    func benchmarkPrivateProxyCapture(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        try MDKPrivateCapturePrototypeBenchmark.runProxy(
            displayID: displayID,
            requestExtendedRange: requestExtendedRange,
            sampleDuration: sampleDuration
        )
    }

    func benchmarkSkyLightDisplayStream(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        request120LikeProperties: Bool
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        try MDKSkyLightDisplayStreamBenchmark.run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            request120LikeProperties: request120LikeProperties
        )
        .appendingNotes(captureRelevantProcessLoadNotes())
    }

    func benchmarkSkyLightDisplayStream(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        minimumFrameTime: Double,
        queueDepth: Int,
        showCursor: Bool,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        try MDKSkyLightDisplayStreamBenchmark.run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            minimumFrameTime: minimumFrameTime,
            queueDepth: queueDepth,
            showCursor: showCursor,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
        .appendingNotes(captureRelevantProcessLoadNotes())
    }

    func benchmarkSkyLightDisplayStreamProcessing(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        minimumFrameTime: Double,
        queueDepth: Int,
        showCursor: Bool,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> MDKSkyLightDisplayStreamProcessingBenchmarkResult {
        try MDKSkyLightDisplayStreamProcessingBenchmark.run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            minimumFrameTime: minimumFrameTime,
            queueDepth: queueDepth,
            showCursor: showCursor,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            processingMode: processingMode
        )
    }

    func benchmarkSkyLightDisplayStreamTuningMatrix(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        candidates: [MDKSkyLightDisplayStreamTuningCandidate] = MDKSkyLightDisplayStreamTuningMatrix.defaultCandidates
    ) throws -> MDKSkyLightDisplayStreamTuningMatrixReport {
        let evaluations = try candidates.map { candidate in
            try MDKSkyLightDisplayStreamTuningEvaluation(
                candidate: candidate,
                result: runSkyLightDisplayStreamBenchmarkInSubprocess(
                    displayID: displayID,
                    sampleDuration: sampleDuration,
                    useMetalStimulus: useMetalStimulus,
                    candidate: candidate
                )
            )
        }

        let bestIndex = MDKSkyLightDisplayStreamTuningMatrix.bestEvaluationIndex(for: evaluations)
        var notes = [
            "Evaluates a fixed set of raw SkyLight SLDisplayStream property combinations on the same display.",
            "Each candidate runs in a fresh child process to avoid in-process stream state contaminating later measurements.",
            "Ranking order: realtime floor >= 60 fps, cadence classification, observed frame rate, then complete-frame count."
        ]
        if let bestIndex,
           evaluations.indices.contains(bestIndex) {
            let bestEvaluation = evaluations[bestIndex]
            notes.append(
                "bestCandidate=\(bestEvaluation.candidate.identifier) observedFrameRate=\(String(format: "%.2f", bestEvaluation.result.observedFrameRate)) cadence=\(bestEvaluation.result.cadenceClassification)"
            )
        }

        return MDKSkyLightDisplayStreamTuningMatrixReport(
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: useMetalStimulus,
            evaluations: evaluations,
            bestEvaluationIndex: bestIndex,
            notes: notes
        )
    }

    func benchmarkSkyLightDisplayStreamProcessingMatrix(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        candidates: [MDKSkyLightDisplayStreamProcessingMatrixCandidate] = MDKSkyLightDisplayStreamProcessingMatrix.defaultCandidates
    ) -> MDKSkyLightDisplayStreamProcessingMatrixReport {
        MDKSkyLightDisplayStreamProcessingMatrix.run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: useMetalStimulus,
            candidates: candidates,
            runBenchmark: { displayID, sampleDuration, useMetalStimulus, candidate in
                try runSkyLightDisplayStreamProcessingBenchmarkInSubprocess(
                    displayID: displayID,
                    sampleDuration: sampleDuration,
                    useMetalStimulus: useMetalStimulus,
                    candidate: candidate
                )
            }
        )
    }

    private func runSkyLightDisplayStreamBenchmarkInSubprocess(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        candidate: MDKSkyLightDisplayStreamTuningCandidate
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])

        var arguments = [
            "--experimental-skylight-displaystream-benchmark-display",
            String(displayID),
            "--sample-duration",
            String(sampleDuration),
            "--minimum-frame-time",
            String(candidate.minimumFrameTime),
            "--queue-depth",
            String(candidate.queueDepth),
            "--json"
        ]
        if candidate.showCursor {
            arguments.append("--show-cursor")
        }
        if useMetalStimulus {
            arguments.append("--with-metal-stimulus")
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard !outputData.isEmpty else {
            let stderrText = String(data: errorData, encoding: .utf8) ?? "No stderr"
            throw NSError(
                domain: "MacDisplayKitHost",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Empty raw SkyLight benchmark output: \(stderrText)"]
            )
        }

        do {
            return try JSONDecoder().decode(MDKSkyLightDisplayStreamBenchmarkResult.self, from: outputData)
        } catch {
            let rawOutput = String(data: outputData, encoding: .utf8) ?? "<non-utf8>"
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MacDisplayKitHost",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to decode raw SkyLight benchmark output",
                    "stdout": rawOutput,
                    "stderr": stderrText
                ]
            )
        }
    }

    private func runSkyLightDisplayStreamProcessingBenchmarkInSubprocess(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool,
        candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate
    ) throws -> MDKSkyLightDisplayStreamProcessingBenchmarkResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])

        var arguments = [
            "--experimental-skylight-displaystream-benchmark-display",
            String(displayID),
            "--sample-duration",
            String(sampleDuration),
            "--minimum-frame-time",
            String(candidate.tuningCandidate.minimumFrameTime),
            "--queue-depth",
            String(candidate.tuningCandidate.queueDepth),
            "--processing-mode",
            candidate.processingMode.rawValue,
            "--json"
        ]
        if candidate.tuningCandidate.showCursor {
            arguments.append("--show-cursor")
        }
        if useMetalStimulus {
            arguments.append("--with-metal-stimulus")
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard !outputData.isEmpty else {
            let stderrText = String(data: errorData, encoding: .utf8) ?? "No stderr"
            throw NSError(
                domain: "MacDisplayKitHost",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Empty raw SkyLight processing benchmark output: \(stderrText)"]
            )
        }

        do {
            return try JSONDecoder().decode(MDKSkyLightDisplayStreamProcessingBenchmarkResult.self, from: outputData)
        } catch {
            let rawOutput = String(data: outputData, encoding: .utf8) ?? "<non-utf8>"
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MacDisplayKitHost",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to decode raw SkyLight processing benchmark output",
                    "stdout": rawOutput,
                    "stderr": stderrText
                ]
            )
        }
    }

    func traceScreenCaptureKitProxyHandshake(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitProxyHandshakeTrace {
        try MDKScreenCaptureKitProxyHandshakeTracer.trace(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func traceScreenCaptureKitPassiveHandshake(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitProxyHandshakeTrace {
        try MDKScreenCaptureKitProxyHandshakeTracer.tracePassive(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func traceScreenCaptureKitTiming(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitTimingTrace {
        try MDKScreenCaptureKitTimingTracer.trace(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
    }

    func inspectScreenCaptureKitRuntime() throws -> MDKScreenCaptureKitRuntimeInventory {
        try MDKScreenCaptureKitRuntimeInspector.inspect()
    }
}

private extension MDKHostBenchmarkController {
    func captureRelevantProcessLoadNotes() -> [String] {
        guard let output = try? captureProcessListSnapshot() else {
            return []
        }

        let interestingProcesses = [
            "WindowServer",
            "colorsync.useragent",
            "colorsyncd",
            "colorsync.displayservices",
            "replayd"
        ]

        let matches = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let tokens = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard tokens.count == 3 else {
                    return nil
                }

                let processPath = String(tokens[2])
                guard let interesting = interestingProcesses.first(where: {
                    processPath == $0 || processPath.hasSuffix("/\($0)")
                }) else {
                    return nil
                }

                return "hostLoad/\(interesting) pcpu=\(tokens[0]) pmem=\(tokens[1])"
            }

        return matches
    }

    func captureProcessListSnapshot() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pcpu,pmem,comm"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return ""
        }

        return String(decoding: data, as: UTF8.self)
    }
}
