import Foundation
import MacDisplayKit
import AppKit

private enum MDKHostCLICommand {
    case listDisplays
    case listTargets
    case screenCaptureKitProxyHandshakeTrace(displayID: UInt32, sampleDuration: TimeInterval, json: Bool)
    case screenCaptureKitTimingTrace(displayID: UInt32, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case privateCapturePlan(json: Bool)
    case privateCaptureProbe(displayID: UInt32, requestExtendedRange: Bool, json: Bool)
    case privateProxyCaptureProbe(displayID: UInt32, requestExtendedRange: Bool, json: Bool)
    case privateDisplayStreamProbe(displayID: UInt32, json: Bool)
    case privateDisplayStreamProbeMatrix(displayID: UInt32, json: Bool)
    case privateCaptureBenchmark(displayID: UInt32, requestExtendedRange: Bool, sampleDuration: TimeInterval, json: Bool)
    case privateProxyCaptureBenchmark(displayID: UInt32, requestExtendedRange: Bool, sampleDuration: TimeInterval, json: Bool)
    case benchmark(
        displayID: UInt32,
        targetIdentifier: String,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        json: Bool
    )
    case benchmarkMatrix(
        displayID: UInt32,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        json: Bool
    )
}

enum MDKHostCommandLine {
    static func runIfRequested(arguments: [String], controller: MDKHostBenchmarkController) -> Int32? {
        guard let command = parse(arguments: arguments) else {
            return nil
        }

        switch command {
        case .listDisplays:
            for display in controller.availableDisplays() {
                print("\(display.id)\t\(display.localizedName)")
            }
            return 0
        case .listTargets:
            for target in controller.availableTargets() {
                print("\(target.identifier)\t\(target.name)")
            }
            return 0
        case .screenCaptureKitProxyHandshakeTrace(let displayID, let sampleDuration, let json):
            do {
                let trace = try controller.traceScreenCaptureKitProxyHandshake(
                    displayID: displayID,
                    sampleDuration: sampleDuration
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(trace)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatScreenCaptureKitProxyHandshakeTrace(trace))
                }
                return trace.succeeded ? 0 : 2
            } catch {
                fputs("Failed to trace ScreenCaptureKit proxy handshake: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitTimingTrace(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: displayID) : nil
                stimulus?.start()
                defer { stimulus?.stop() }

                let trace = try controller.traceScreenCaptureKitTiming(
                    displayID: displayID,
                    sampleDuration: sampleDuration
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(trace)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatScreenCaptureKitProxyHandshakeTrace(trace))
                }
                return trace.succeeded ? 0 : 2
            } catch {
                fputs("Failed to trace ScreenCaptureKit timing: \(error)\n", stderr)
                return 1
            }
        case .privateCapturePlan(let json):
            let plan = controller.privateCapturePrototypePlan()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    let data = try encoder.encode(plan)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } catch {
                    fputs("Failed to encode private capture prototype plan: \(error)\n", stderr)
                    return 1
                }
            } else {
                print(MDKHostBenchmarkFormatter.formatPrivateCapturePrototypePlan(plan))
            }
            return 0
        case .privateCaptureProbe(let displayID, let requestExtendedRange, let json):
            do {
                let result = try controller.probePrivateCaptureSingleFrame(
                    displayID: displayID,
                    requestExtendedRange: requestExtendedRange
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureProbeResult(result))
                }
                return result.status == 0 && result.surfacePopulated ? 0 : 2
            } catch {
                fputs("Failed to run private capture probe: \(error)\n", stderr)
                return 1
            }
        case .privateProxyCaptureProbe(let displayID, let requestExtendedRange, let json):
            do {
                let result = try controller.probePrivateProxyCaptureSingleFrame(
                    displayID: displayID,
                    requestExtendedRange: requestExtendedRange
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureProbeResult(result))
                }
                return result.status == 0 && result.surfacePopulated ? 0 : 2
            } catch {
                fputs("Failed to run private proxy capture probe: \(error)\n", stderr)
                return 1
            }
        case .privateDisplayStreamProbe(let displayID, let json):
            do {
                let result = try controller.probePrivateDisplayStream(displayID: displayID)
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureProbeResult(result))
                }
                return result.status == 0 ? 0 : 2
            } catch {
                fputs("Failed to run private display stream probe: \(error)\n", stderr)
                return 1
            }
        case .privateDisplayStreamProbeMatrix(let displayID, let json):
            do {
                let results = try controller.probePrivateDisplayStreamMatrix(displayID: displayID)
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(results)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureProbeResults(results))
                }
                return results.allSatisfy { $0.status == 0 } ? 0 : 2
            } catch {
                fputs("Failed to run private display stream probe matrix: \(error)\n", stderr)
                return 1
            }
        case .privateCaptureBenchmark(let displayID, let requestExtendedRange, let sampleDuration, let json):
            do {
                let result = try controller.benchmarkPrivateCapture(
                    displayID: displayID,
                    requestExtendedRange: requestExtendedRange,
                    sampleDuration: sampleDuration
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureBenchmarkResult(result))
                }
                return result.probe.status == 0 && result.probe.surfacePopulated ? 0 : 2
            } catch {
                fputs("Failed to run private capture benchmark: \(error)\n", stderr)
                return 1
            }
        case .privateProxyCaptureBenchmark(let displayID, let requestExtendedRange, let sampleDuration, let json):
            do {
                let result = try controller.benchmarkPrivateProxyCapture(
                    displayID: displayID,
                    requestExtendedRange: requestExtendedRange,
                    sampleDuration: sampleDuration
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatPrivateCaptureBenchmarkResult(result))
                }
                return result.probe.status == 0 && result.probe.surfacePopulated ? 0 : 2
            } catch {
                fputs("Failed to run private proxy capture benchmark: \(error)\n", stderr)
                return 1
            }
        case .benchmark(let displayID, let targetIdentifier, let intent, let processingMode, let json):
            guard let display = controller.display(id: displayID) else {
                fputs("Unknown display id: \(displayID)\n", stderr)
                return 64
            }
            guard let target = controller.target(identifier: targetIdentifier) else {
                fputs("Unknown target identifier: \(targetIdentifier)\n", stderr)
                return 64
            }

            let suite = controller.runBenchmark(
                display: display,
                target: target,
                intent: intent,
                processingMode: processingMode
            )
            if json {
                do {
                    let data = try MDKCaptureBenchmarkReport.jsonData(for: suite)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } catch {
                    fputs("Failed to encode benchmark report: \(error)\n", stderr)
                    return 1
                }
            } else {
                print(MDKHostBenchmarkFormatter.formatReport(for: suite))
            }

            return suite.assessment.passed ? 0 : 2
        case .benchmarkMatrix(let displayID, let intent, let processingMode, let json):
            guard let display = controller.display(id: displayID) else {
                fputs("Unknown display id: \(displayID)\n", stderr)
                return 64
            }

            let matrix = controller.runCaptureOnlyValidationMatrix(
                display: display,
                intent: intent,
                processingMode: processingMode
            )
            if json {
                do {
                    let data = try MDKCaptureBenchmarkReport.jsonData(for: matrix)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } catch {
                    fputs("Failed to encode benchmark matrix report: \(error)\n", stderr)
                    return 1
                }
            } else {
                for suite in matrix.suites {
                    print(MDKHostBenchmarkFormatter.formatReport(for: suite))
                    print("")
                }
            }

            return matrix.passed ? 0 : 2
        }
    }

    private static func parse(arguments: [String]) -> MDKHostCLICommand? {
        let tokens = Array(arguments.dropFirst())
        guard !tokens.isEmpty else {
            return nil
        }

        if tokens.contains("--list-displays") {
            return .listDisplays
        }

        if tokens.contains("--list-targets") {
            return .listTargets
        }

        if let traceDisplayIndex = tokens.firstIndex(of: "--experimental-screencapturekit-proxy-handshake-display"),
           tokens.indices.contains(traceDisplayIndex + 1),
           let displayID = UInt32(tokens[traceDisplayIndex + 1]) {
            return .screenCaptureKitProxyHandshakeTrace(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let traceDisplayIndex = tokens.firstIndex(of: "--experimental-screencapturekit-timing-display"),
           tokens.indices.contains(traceDisplayIndex + 1),
           let displayID = UInt32(tokens[traceDisplayIndex + 1]) {
            return .screenCaptureKitTimingTrace(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if tokens.contains("--experimental-private-hw-capture-plan") {
            return .privateCapturePlan(json: tokens.contains("--json"))
        }

        if let probeDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-probe-display"),
           tokens.indices.contains(probeDisplayIndex + 1),
           let displayID = UInt32(tokens[probeDisplayIndex + 1]) {
            return .privateCaptureProbe(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-probe-hdr"),
                json: tokens.contains("--json")
            )
        }

        if let probeDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-proxy-probe-display"),
           tokens.indices.contains(probeDisplayIndex + 1),
           let displayID = UInt32(tokens[probeDisplayIndex + 1]) {
            return .privateProxyCaptureProbe(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-proxy-probe-hdr"),
                json: tokens.contains("--json")
            )
        }

        if let probeDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-stream-probe-display"),
           tokens.indices.contains(probeDisplayIndex + 1),
           let displayID = UInt32(tokens[probeDisplayIndex + 1]) {
            return .privateDisplayStreamProbe(
                displayID: displayID,
                json: tokens.contains("--json")
            )
        }

        if let probeDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-stream-probe-matrix-display"),
           tokens.indices.contains(probeDisplayIndex + 1),
           let displayID = UInt32(tokens[probeDisplayIndex + 1]) {
            return .privateDisplayStreamProbeMatrix(
                displayID: displayID,
                json: tokens.contains("--json")
            )
        }

        if let benchmarkDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-benchmark-display"),
           tokens.indices.contains(benchmarkDisplayIndex + 1),
           let displayID = UInt32(tokens[benchmarkDisplayIndex + 1]) {
            return .privateCaptureBenchmark(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-benchmark-hdr"),
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let benchmarkDisplayIndex = tokens.firstIndex(of: "--experimental-private-hw-capture-proxy-benchmark-display"),
           tokens.indices.contains(benchmarkDisplayIndex + 1),
           let displayID = UInt32(tokens[benchmarkDisplayIndex + 1]) {
            return .privateProxyCaptureBenchmark(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-proxy-benchmark-hdr"),
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let matrixDisplayIndex = tokens.firstIndex(of: "--benchmark-matrix-display"),
           tokens.indices.contains(matrixDisplayIndex + 1),
           let displayID = UInt32(tokens[matrixDisplayIndex + 1]) {
            let intent: MDKCapturePlanIntent = tokens.contains("--compare-backends")
                ? .compareBackends
                : .validateDefaultBackend
            let processingMode = parseProcessingMode(tokens: tokens) ?? .metalCopy
            let json = tokens.contains("--json")
            return .benchmarkMatrix(
                displayID: displayID,
                intent: intent,
                processingMode: processingMode,
                json: json
            )
        }

        guard let displayIndex = tokens.firstIndex(of: "--benchmark-display"),
              let targetIndex = tokens.firstIndex(of: "--benchmark-target"),
              tokens.indices.contains(displayIndex + 1),
              tokens.indices.contains(targetIndex + 1),
              let displayID = UInt32(tokens[displayIndex + 1]) else {
            return nil
        }

        let targetIdentifier = tokens[targetIndex + 1]
        let intent: MDKCapturePlanIntent = tokens.contains("--compare-backends")
            ? .compareBackends
            : .validateDefaultBackend
        let processingMode = parseProcessingMode(tokens: tokens) ?? .metalCopy
        let json = tokens.contains("--json")
        return .benchmark(
            displayID: displayID,
            targetIdentifier: targetIdentifier,
            intent: intent,
            processingMode: processingMode,
            json: json
        )
    }

    private static func parseProcessingMode(tokens: [String]) -> MDKCaptureBenchmarkProcessingMode? {
        guard let index = tokens.firstIndex(of: "--processing-mode"),
              tokens.indices.contains(index + 1) else {
            return nil
        }

        return MDKCaptureBenchmarkProcessingMode(rawValue: tokens[index + 1])
    }

    private static func parseSampleDuration(tokens: [String]) -> TimeInterval? {
        guard let index = tokens.firstIndex(of: "--sample-duration"),
              tokens.indices.contains(index + 1),
              let duration = TimeInterval(tokens[index + 1]) else {
            return nil
        }

        return duration
    }
}
