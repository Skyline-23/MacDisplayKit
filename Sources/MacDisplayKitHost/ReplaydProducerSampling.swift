import Foundation
import MacDisplayKit
import MacDisplayCaptureKit

struct MDKReplaydProducerTraceReport: Codable, Equatable, Sendable {
    let passiveTrace: MDKScreenCaptureKitProxyHandshakeTrace
    let replaydSample: MDKReplaydProducerSampleReport
    let replaydSampleExitStatus: Int32
    let replaydSampleDelay: TimeInterval
}

struct MDKReplaydProducerComparisonReport: Codable, Equatable, Sendable {
    let baseline: MDKReplaydProducerTraceReport
    let stimulus: MDKReplaydProducerTraceReport
    let comparison: MDKReplaydProducerSampleComparison
}

struct MDKReplaydProducerTraceSeriesReport: Codable, Equatable, Sendable {
    let useMetalStimulus: Bool
    let traces: [MDKReplaydProducerTraceReport]
    let summary: MDKReplaydProducerSampleSeriesSummary
}

struct MDKReplaydXctraceArtifactReport: Codable, Equatable, Sendable {
    let passiveTrace: MDKScreenCaptureKitProxyHandshakeTrace
    let replaydPID: Int32
    let traceDirectoryPath: String
    let tracePath: String
    let tocPath: String
    let tocByteCount: Int
    let contextSwitchTable: MDKReplaydXctraceTableArtifact
    let threadStateTable: MDKReplaydXctraceTableArtifact
    let systemCallTable: MDKReplaydXctraceTableArtifact
    let timeSampleTable: MDKReplaydXctraceTableArtifact
    let unifiedLog: MDKReplaydUnifiedLogArtifact
    let notes: [String]
}

enum MDKReplaydProducerSamplerError: Error {
    case replaydNotRunning
    case sampleFailed(status: Int32, output: String)
}

private struct MDKReplaydProducerSampleExecution: Sendable {
    let sampleReport: MDKReplaydProducerSampleReport
    let exitStatus: Int32
    let delay: TimeInterval
}

private struct MDKReplaydXctraceExecution: Sendable {
    let report: MDKReplaydXctraceArtifactReport
}

private actor MDKReplaydProducerSampleCoordinator {
    func capture(
        replaydPID: Int32,
        requestedSampleDuration: TimeInterval
    ) async throws -> MDKReplaydProducerSampleExecution {
        let replaydSampleDuration = min(max(1.0, requestedSampleDuration / 3.0), 1.5)
        let replaydSampleDelay = min(max(0.25, requestedSampleDuration / 6.0), 0.5)
        let replaydSampleIntervalMilliseconds = 1
        let sampleOutputURL = Self.temporarySampleOutputURL()

        try await Task.sleep(for: .seconds(replaydSampleDelay))

        let sampleExitStatus = try Self.runReplaydSample(
            replaydPID: replaydPID,
            sampleDuration: replaydSampleDuration,
            sampleIntervalMilliseconds: replaydSampleIntervalMilliseconds,
            outputURL: sampleOutputURL
        )
        let sampleText = (try? String(contentsOf: sampleOutputURL, encoding: .utf8)) ?? ""

        guard sampleExitStatus == 0, !sampleText.isEmpty else {
            throw MDKReplaydProducerSamplerError.sampleFailed(
                status: sampleExitStatus,
                output: sampleText
            )
        }

        let sampleReport = MDKReplaydProducerSampleParser.analyze(
            sampleText: sampleText,
            replaydPID: replaydPID,
            sampleDuration: replaydSampleDuration,
            sampleIntervalMilliseconds: replaydSampleIntervalMilliseconds
        )

        return MDKReplaydProducerSampleExecution(
            sampleReport: sampleReport,
            exitStatus: sampleExitStatus,
            delay: replaydSampleDelay
        )
    }

    nonisolated private static func runReplaydSample(
        replaydPID: Int32,
        sampleDuration: TimeInterval,
        sampleIntervalMilliseconds: Int,
        outputURL: URL
    ) throws -> Int32 {
        let durationArgument = String(Int(ceil(sampleDuration)))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(replaydPID),
            durationArgument,
            String(sampleIntervalMilliseconds)
        ]

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func temporarySampleOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mdk-replayd-sample-\(UUID().uuidString)")
            .appendingPathExtension("txt")
    }
}

private actor MDKReplaydXctraceCoordinator {
    func capture(
        replaydPID: Int32,
        sampleDuration: TimeInterval,
        passiveTrace: MDKScreenCaptureKitProxyHandshakeTrace
    ) async throws -> MDKReplaydXctraceExecution {
        let traceDirectoryURL = Self.temporaryTraceDirectoryURL()
        try FileManager.default.createDirectory(
            at: traceDirectoryURL,
            withIntermediateDirectories: true
        )

        let traceURL = traceDirectoryURL.appendingPathComponent("replayd-system.trace")
        let tocURL = traceDirectoryURL.appendingPathComponent("toc.xml")
        let contextSwitchURL = traceDirectoryURL.appendingPathComponent("context-switch.xml")
        let threadStateURL = traceDirectoryURL.appendingPathComponent("thread-state.xml")
        let syscallURL = traceDirectoryURL.appendingPathComponent("syscall.xml")
        let timeSampleURL = traceDirectoryURL.appendingPathComponent("time-sample.xml")
        let logURL = traceDirectoryURL.appendingPathComponent("replayd-log.ndjson")

        let captureDuration = max(2, Int(ceil(min(sampleDuration, 5))))

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "record",
                "--template", "System Trace",
                "--attach", String(replaydPID),
                "--time-limit", "\(captureDuration)s",
                "--output", traceURL.path,
                "--no-prompt"
            ]
        )

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--toc"
            ],
            outputURL: tocURL
        )

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"context-switch\"]"
            ],
            outputURL: contextSwitchURL
        )

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"thread-state\"]"
            ],
            outputURL: threadStateURL
        )

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"syscall\"]"
            ],
            outputURL: syscallURL
        )

        try Self.runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-sample\"]"
            ],
            outputURL: timeSampleURL
        )

        try Self.runProcess(
            executablePath: "/usr/bin/log",
            arguments: [
                "show",
                "--last", "\(captureDuration + 2)s",
                "--style", "ndjson",
                "--process", "replayd",
                "--info",
                "--debug",
                "--signpost",
                "--no-pager"
            ],
            outputURL: logURL
        )

        let tocText = try String(contentsOf: tocURL, encoding: .utf8)
        let contextSwitchText = try String(contentsOf: contextSwitchURL, encoding: .utf8)
        let threadStateText = try String(contentsOf: threadStateURL, encoding: .utf8)
        let syscallText = try String(contentsOf: syscallURL, encoding: .utf8)
        let timeSampleText = try String(contentsOf: timeSampleURL, encoding: .utf8)
        let logText = try String(contentsOf: logURL, encoding: .utf8)

        let contextSwitchTable = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "context-switch",
            outputPath: contextSwitchURL.path,
            exportText: contextSwitchText
        )
        let threadStateTable = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "thread-state",
            outputPath: threadStateURL.path,
            exportText: threadStateText
        )
        let systemCallTable = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "syscall",
            outputPath: syscallURL.path,
            exportText: syscallText
        )
        let timeSampleTable = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "time-sample",
            outputPath: timeSampleURL.path,
            exportText: timeSampleText
        )
        let unifiedLog = MDKReplaydXctraceArtifactParser.summarizeUnifiedLogArtifact(
            outputPath: logURL.path,
            logText: logText
        )

        var notes: [String] = []
        if !contextSwitchTable.containsRows {
            notes.append("xctrace context-switch export returned schema-only XML on this run.")
        }
        if !threadStateTable.containsRows {
            notes.append("xctrace thread-state export returned schema-only XML on this run.")
        }
        if !systemCallTable.containsRows {
            notes.append("xctrace syscall export returned schema-only XML on this run.")
        }
        if !timeSampleTable.containsRows {
            notes.append("xctrace time-sample export returned schema-only XML on this run.")
        }
        if contextSwitchTable.containsRows || threadStateTable.containsRows || systemCallTable.containsRows || timeSampleTable.containsRows {
            notes.append(
                "xctrace exported replayd rows: context-switch=\(contextSwitchTable.rowCount) thread-state=\(threadStateTable.rowCount) syscall=\(systemCallTable.rowCount) time-sample=\(timeSampleTable.rowCount)."
            )
        }
        if !contextSwitchTable.replaydRunningThreadCadenceSummaries.isEmpty {
            let dominantThreads = contextSwitchTable.replaydRunningThreadCadenceSummaries.prefix(2).map {
                "\($0.threadID)=\($0.cadenceClassification) count=\($0.eventCount)"
            }
            let dominantSummary = dominantThreads.joined(separator: ", ")
            notes.append(
                "replayd context-switch running cadences \(dominantSummary)."
            )
        }
        if !threadStateTable.replaydRunnableSourceSummaries.isEmpty {
            let dominantRunnableSources = threadStateTable.replaydRunnableSourceSummaries.prefix(2).map { summary in
                let topSources = summary.runnableSourceHistogram
                    .sorted { lhs, rhs in
                        if lhs.value == rhs.value {
                            return lhs.key < rhs.key
                        }
                        return lhs.value > rhs.value
                    }
                    .prefix(2)
                    .map { "\($0.value)x \($0.key)" }
                    .joined(separator: ", ")
                return "\(summary.threadID)=\(topSources)"
            }
            let runnableSummary = dominantRunnableSources.joined(separator: " | ")
            notes.append("replayd thread-state runnable sources \(runnableSummary).")
        }
        if !contextSwitchTable.replaydRunningThreadCadenceSummaries.isEmpty,
           !threadStateTable.replaydRunnableSourceSummaries.isEmpty {
            let runnableSourcesByThread = Dictionary(
                uniqueKeysWithValues: threadStateTable.replaydRunnableSourceSummaries.map { ($0.threadID, $0) }
            )
            let dominantWindowServerWakeSummaries = contextSwitchTable.replaydRunningThreadCadenceSummaries
                .prefix(2)
                .compactMap { summary -> String? in
                    guard let runnableSummary = runnableSourcesByThread[summary.threadID] else {
                        return nil
                    }
                    let windowServerWakeCount = runnableSummary.runnableSourceHistogram.reduce(into: 0) { partialResult, entry in
                        if entry.key.contains("WindowServer, pid: 408") {
                            partialResult += entry.value
                        }
                    }
                    guard windowServerWakeCount > 0 else {
                        return nil
                    }
                    return "\(summary.threadID)=\(windowServerWakeCount)x WindowServer"
                }
            if !dominantWindowServerWakeSummaries.isEmpty {
                notes.append(
                    "thread-state shows dominant replayd running threads made runnable by WindowServer \(dominantWindowServerWakeSummaries.joined(separator: \", \"))."
                )
            }
        }
        if !systemCallTable.hotSymbolHistogram.isEmpty {
            notes.append(
                "replayd syscall backtraces hit producer symbols \(systemCallTable.hotSymbolHistogram)."
            )
        }
        if let roEnqueueSampleBufferCadence = systemCallTable.hotSymbolCadenceSummaries.first(where: { $0.symbolName == "roEnqueueSampleBuffer" }) {
            notes.append(
                "replayd syscall backtraces classified roEnqueueSampleBuffer cadence as \(roEnqueueSampleBufferCadence.cadenceClassification) over \(roEnqueueSampleBufferCadence.eventCount) sampled rows."
            )
        }
        if let roEnqueueSampleBufferSyscalls = systemCallTable.hotSymbolSyscallSummaries.first(
            where: { $0.symbolName == "roEnqueueSampleBuffer" }
        ) {
            notes.append(
                "replayd syscall backtraces saw roEnqueueSampleBuffer syscall histogram \(roEnqueueSampleBufferSyscalls.syscallHistogram)."
            )
            if roEnqueueSampleBufferSyscalls.syscallHistogram["write"] == nil {
                notes.append(
                    "the current xctrace window did not sample any roEnqueueSampleBuffer/write rows, so write-only cadence is unavailable on this run."
                )
            }
        }
        if let roEnqueueSampleBufferWriteCadence = systemCallTable.hotSymbolSyscallCadenceSummaries.first(
            where: { $0.symbolName == "roEnqueueSampleBuffer" && $0.syscallName == "write" }
        ) {
            notes.append(
                "replayd syscall backtraces classified roEnqueueSampleBuffer/write cadence as \(roEnqueueSampleBufferWriteCadence.cadenceClassification) over \(roEnqueueSampleBufferWriteCadence.eventCount) sampled rows."
            )
        }
        if
            let enqueueFailures = unifiedLog.enqueueFailureSummary,
            enqueueFailures.operationHistogram.count == 1,
            enqueueFailures.operationHistogram["3"] != nil,
            systemCallTable.hotSymbolHistogram["roEnqueueSampleBuffer"] != nil
        {
            notes.append(
                "opType=3 enqueue failures coincided with replayd syscall backtraces through roEnqueueSampleBuffer, tying the live failures to sample-buffer producer traffic."
            )
        }
        if unifiedLog.matchedLineCount == 0 {
            notes.append("replayd unified log did not emit matching capture markers in the requested window.")
        }
        if let enqueueFailures = unifiedLog.enqueueFailureSummary {
            notes.append(
                "replayd unified log captured \(enqueueFailures.eventCount) _SCRemoteQueue_Enqueue failures with \(enqueueFailures.cadenceClassification) spacing."
            )
            if enqueueFailures.errorHistogram["-19641"] != nil {
                notes.append(
                    "static replayd disassembly shows err=-19641 bypasses the queue-full and client-terminated special cases and lands in the generic enqueue-error branch after _FigRemoteOperationSenderResetIfFullAndEnqueueOperation."
                )
            }
            if enqueueFailures.senderProgramCounterHistogram.count == 1,
               let senderPC = enqueueFailures.senderProgramCounterHistogram.keys.first {
                notes.append(
                    "replayd enqueue failures collapsed to senderProgramCounter=\(senderPC) in this capture window."
                )
            }
        }
        if unifiedLog.matchedLines.contains(where: { $0.localizedCaseInsensitiveContains("screenframeCount=0") }) {
            notes.append("replayd health-monitor log reported screenframeCount=0 during the paired trace window.")
        }
        if !passiveTrace.succeeded {
            notes.append("paired passive trace did not reach a succeeded state during xctrace capture.")
        }

        return MDKReplaydXctraceExecution(
            report: MDKReplaydXctraceArtifactReport(
                passiveTrace: passiveTrace,
                replaydPID: replaydPID,
                traceDirectoryPath: traceDirectoryURL.path,
                tracePath: traceURL.path,
                tocPath: tocURL.path,
                tocByteCount: tocText.lengthOfBytes(using: .utf8),
                contextSwitchTable: contextSwitchTable,
                threadStateTable: threadStateTable,
                systemCallTable: systemCallTable,
                timeSampleTable: timeSampleTable,
                unifiedLog: unifiedLog,
                notes: notes
            )
        )
    }

    nonisolated private static func runProcess(
        executablePath: String,
        arguments: [String],
        outputURL: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let outputURL {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MDKReplaydProducerSamplerError.sampleFailed(
                    status: process.terminationStatus,
                    output: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                )
            }
            return
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let outputText = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw MDKReplaydProducerSamplerError.sampleFailed(
                status: process.terminationStatus,
                output: outputText
            )
        }
    }

    nonisolated private static func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mdk-replayd-xctrace-\(UUID().uuidString)", isDirectory: true)
    }
}

enum MDKReplaydProducerSampler {
    @MainActor
    static func capturePassiveTrace(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool = false
    ) async throws -> MDKReplaydProducerTraceReport {
        try await performPassiveTraceCapture(
            controller: controller,
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: useMetalStimulus
        )
    }

    @MainActor
    static func capturePassiveTraceComparison(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) async throws -> MDKReplaydProducerComparisonReport {
        let baseline = try await capturePassiveTrace(
            controller: controller,
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: false
        )
        let stimulus = try await capturePassiveTrace(
            controller: controller,
            displayID: displayID,
            sampleDuration: sampleDuration,
            useMetalStimulus: true
        )

        return MDKReplaydProducerComparisonReport(
            baseline: baseline,
            stimulus: stimulus,
            comparison: MDKReplaydProducerSampleComparator.compare(
                baseline: baseline.replaydSample,
                stimulus: stimulus.replaydSample
            )
        )
    }

    @MainActor
    static func capturePassiveTraceSeries(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval,
        windowCount: Int,
        useMetalStimulus: Bool
    ) async throws -> MDKReplaydProducerTraceSeriesReport {
        let replaydPID = try currentReplaydPID()
        let coordinator = MDKReplaydProducerSampleCoordinator()
        let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: displayID) : nil
        stimulus?.start()
        defer { stimulus?.stop() }

        var traces: [MDKReplaydProducerTraceReport] = []
        traces.reserveCapacity(windowCount)
        for _ in 0..<windowCount {
            let trace = try await collectPassiveTrace(
                controller: controller,
                displayID: displayID,
                sampleDuration: sampleDuration,
                replaydPID: replaydPID,
                coordinator: coordinator
            )
            traces.append(trace)
        }

        return MDKReplaydProducerTraceSeriesReport(
            useMetalStimulus: useMetalStimulus,
            traces: traces,
            summary: MDKReplaydProducerSampleSeriesAnalyzer.summarize(
                reports: traces.map(\.replaydSample)
            )
        )
    }

    @MainActor
    static func capturePassiveTraceWithXctraceArtifacts(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool
    ) async throws -> MDKReplaydXctraceArtifactReport {
        let replaydPID = try currentReplaydPID()
        let xctraceCoordinator = MDKReplaydXctraceCoordinator()
        let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: displayID) : nil
        stimulus?.start()
        defer { stimulus?.stop() }

        let passiveTrace = try controller.traceScreenCaptureKitPassiveHandshake(
            displayID: displayID,
            sampleDuration: sampleDuration
        )
        let execution = try await xctraceCoordinator.capture(
            replaydPID: replaydPID,
            sampleDuration: sampleDuration,
            passiveTrace: passiveTrace
        )
        return execution.report
    }

    @MainActor
    private static func performPassiveTraceCapture(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval,
        useMetalStimulus: Bool
    ) async throws -> MDKReplaydProducerTraceReport {
        let replaydPID = try currentReplaydPID()
        let coordinator = MDKReplaydProducerSampleCoordinator()
        let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: displayID) : nil
        stimulus?.start()
        defer { stimulus?.stop() }

        return try await collectPassiveTrace(
            controller: controller,
            displayID: displayID,
            sampleDuration: sampleDuration,
            replaydPID: replaydPID,
            coordinator: coordinator
        )
    }

    @MainActor
    private static func collectPassiveTrace(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval,
        replaydPID: Int32,
        coordinator: MDKReplaydProducerSampleCoordinator
    ) async throws -> MDKReplaydProducerTraceReport {

        async let sampleExecution = coordinator.capture(
            replaydPID: replaydPID,
            requestedSampleDuration: sampleDuration
        )

        let passiveTrace = try controller.traceScreenCaptureKitPassiveHandshake(
            displayID: displayID,
            sampleDuration: sampleDuration
        )

        let execution = try await sampleExecution

        return MDKReplaydProducerTraceReport(
            passiveTrace: passiveTrace,
            replaydSample: execution.sampleReport,
            replaydSampleExitStatus: execution.exitStatus,
            replaydSampleDelay: execution.delay
        )
    }

    private static func currentReplaydPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "replayd"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MDKReplaydProducerSamplerError.replaydNotRunning
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: outputData, as: UTF8.self)
        guard let firstLine = outputText
            .split(whereSeparator: \.isNewline)
            .first,
              let pid = Int32(firstLine)
        else {
            throw MDKReplaydProducerSamplerError.replaydNotRunning
        }

        return pid
    }
}
