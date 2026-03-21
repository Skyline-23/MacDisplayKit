import Foundation
import MacDisplayKit
import MacDisplayCaptureKit

struct MDKReplaydProducerTraceReport: Codable, Equatable, Sendable {
    let passiveTrace: MDKScreenCaptureKitProxyHandshakeTrace
    let replaydSample: MDKReplaydProducerSampleReport
    let replaydSampleExitStatus: Int32
    let replaydSampleDelay: TimeInterval
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

enum MDKReplaydProducerSampler {
    @MainActor
    static func capturePassiveTrace(
        controller: MDKHostBenchmarkController,
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) async throws -> MDKReplaydProducerTraceReport {
        let replaydPID = try currentReplaydPID()
        let coordinator = MDKReplaydProducerSampleCoordinator()
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
