import Foundation
import MacDisplayKit
import MacDisplayCaptureKit
import AppKit

private enum MDKHostCLICommand {
    case listDisplays
    case listTargets
    case screenCaptureKitRuntimeInventory(json: Bool)
    case screenCaptureKitProxyHandshakeTrace(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool)
    case screenCaptureKitPassiveHandshakeTrace(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case screenCaptureKitReplaydProducerTrace(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case screenCaptureKitReplaydProducerCompare(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool)
    case screenCaptureKitReplaydProducerSeries(displayID: UInt32?, sampleDuration: TimeInterval, windowCount: Int, json: Bool, useMetalStimulus: Bool)
    case screenCaptureKitReplaydXctraceArtifacts(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case screenCaptureKitWindowServerXctraceArtifacts(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case screenCaptureKitTimingTrace(displayID: UInt32?, sampleDuration: TimeInterval, json: Bool, useMetalStimulus: Bool)
    case privateCapturePlan(json: Bool)
    case privateCaptureProbe(displayID: UInt32?, requestExtendedRange: Bool, json: Bool)
    case privateProxyCaptureProbe(displayID: UInt32?, requestExtendedRange: Bool, json: Bool)
    case privateDisplayStreamProbe(displayID: UInt32?, json: Bool)
    case privateDisplayStreamProbeMatrix(displayID: UInt32?, json: Bool)
    case privateCaptureBenchmark(displayID: UInt32?, requestExtendedRange: Bool, sampleDuration: TimeInterval, json: Bool)
    case privateProxyCaptureBenchmark(displayID: UInt32?, requestExtendedRange: Bool, sampleDuration: TimeInterval, json: Bool)
    case skyLightDisplayStreamBenchmark(
        displayID: UInt32?,
        sampleDuration: TimeInterval,
        request120LikeProperties: Bool,
        minimumFrameTimeOverride: Double?,
        queueDepthOverride: Int?,
        showCursor: Bool,
        json: Bool,
        useMetalStimulus: Bool
    )
    case benchmark(
        displayID: UInt32?,
        targetIdentifier: String,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        json: Bool
    )
    case benchmarkMatrix(
        displayID: UInt32?,
        intent: MDKCapturePlanIntent,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        json: Bool
    )
}

enum MDKHostCommandLine {
    @MainActor
    static func runIfRequested(arguments: [String], controller: MDKHostBenchmarkController) async -> Int32? {
        guard let command = parse(arguments: arguments) else {
            return nil
        }

        switch command {
        case .listDisplays:
            let defaultDisplayID = controller.defaultDisplay()?.id
            for display in controller.availableDisplays() {
                let marker = display.id == defaultDisplayID ? "*" : " "
                print("\(marker)\t\(display.id)\t\(display.localizedName)")
            }
            return 0
        case .listTargets:
            for target in controller.availableTargets() {
                print("\(target.identifier)\t\(target.name)")
            }
            return 0
        case .screenCaptureKitRuntimeInventory(let json):
            do {
                let inventory = try controller.inspectScreenCaptureKitRuntime()
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(inventory)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(formatScreenCaptureKitRuntimeInventory(inventory))
                }
                return 0
            } catch {
                fputs("Failed to inspect ScreenCaptureKit runtime: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitProxyHandshakeTrace(let displayID, let sampleDuration, let json):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let trace = try controller.traceScreenCaptureKitProxyHandshake(
                    displayID: resolvedDisplayID,
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
        case .screenCaptureKitPassiveHandshakeTrace(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: resolvedDisplayID) : nil
                stimulus?.start()
                defer { stimulus?.stop() }

                let trace = try controller.traceScreenCaptureKitPassiveHandshake(
                    displayID: resolvedDisplayID,
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
                fputs("Failed to trace passive ScreenCaptureKit handshake: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitReplaydProducerTrace(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let report = try await MDKReplaydProducerSampler.capturePassiveTrace(
                    controller: controller,
                    displayID: resolvedDisplayID,
                    sampleDuration: sampleDuration,
                    useMetalStimulus: useMetalStimulus
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatReplaydProducerTraceReport(report))
                }
                return 0
            } catch {
                fputs("Failed to capture replayd producer trace: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitReplaydProducerCompare(let displayID, let sampleDuration, let json):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let report = try await MDKReplaydProducerSampler.capturePassiveTraceComparison(
                    controller: controller,
                    displayID: resolvedDisplayID,
                    sampleDuration: sampleDuration
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatReplaydProducerComparisonReport(report))
                }
                return 0
            } catch {
                fputs("Failed to compare replayd producer traces: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitReplaydProducerSeries(let displayID, let sampleDuration, let windowCount, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let report = try await MDKReplaydProducerSampler.capturePassiveTraceSeries(
                    controller: controller,
                    displayID: resolvedDisplayID,
                    sampleDuration: sampleDuration,
                    windowCount: windowCount,
                    useMetalStimulus: useMetalStimulus
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatReplaydProducerSeriesReport(report))
                }
                return 0
            } catch {
                fputs("Failed to capture replayd producer trace series: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitReplaydXctraceArtifacts(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let report = try await MDKReplaydProducerSampler.capturePassiveTraceWithXctraceArtifacts(
                    controller: controller,
                    displayID: resolvedDisplayID,
                    sampleDuration: sampleDuration,
                    useMetalStimulus: useMetalStimulus
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatReplaydXctraceArtifactReport(report))
                }
                return 0
            } catch {
                fputs("Failed to capture replayd xctrace artifacts: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitWindowServerXctraceArtifacts(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let report = try await MDKReplaydProducerSampler.capturePassiveTraceWithWindowServerXctraceArtifacts(
                    controller: controller,
                    displayID: resolvedDisplayID,
                    sampleDuration: sampleDuration,
                    useMetalStimulus: useMetalStimulus
                )
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(report)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatWindowServerXctraceArtifactReport(report))
                }
                return 0
            } catch {
                fputs("Failed to capture WindowServer xctrace artifacts: \(error)\n", stderr)
                return 1
            }
        case .screenCaptureKitTimingTrace(let displayID, let sampleDuration, let json, let useMetalStimulus):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: resolvedDisplayID) : nil
                stimulus?.start()
                defer { stimulus?.stop() }

                let trace = try controller.traceScreenCaptureKitTiming(
                    displayID: resolvedDisplayID,
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let result = try controller.probePrivateCaptureSingleFrame(
                    displayID: resolvedDisplayID,
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let result = try controller.probePrivateProxyCaptureSingleFrame(
                    displayID: resolvedDisplayID,
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let result = try controller.probePrivateDisplayStream(displayID: resolvedDisplayID)
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let results = try controller.probePrivateDisplayStreamMatrix(displayID: resolvedDisplayID)
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let result = try controller.benchmarkPrivateCapture(
                    displayID: resolvedDisplayID,
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
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let result = try controller.benchmarkPrivateProxyCapture(
                    displayID: resolvedDisplayID,
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
        case .skyLightDisplayStreamBenchmark(
            let displayID,
            let sampleDuration,
            let request120LikeProperties,
            let minimumFrameTimeOverride,
            let queueDepthOverride,
            let showCursor,
            let json,
            let useMetalStimulus
        ):
            do {
                let resolvedDisplayID = try resolveDisplayID(displayID, controller: controller)
                let stimulus = useMetalStimulus ? MDKHostMetalStimulus(displayID: resolvedDisplayID) : nil
                stimulus?.start()
                defer { stimulus?.stop() }
                let result: MDKSkyLightDisplayStreamBenchmarkResult
                if minimumFrameTimeOverride != nil || queueDepthOverride != nil || showCursor {
                    let resolvedMinimumFrameTime = minimumFrameTimeOverride
                        ?? (request120LikeProperties ? (1.0 / 120.0) : 0.0)
                    let resolvedQueueDepth = queueDepthOverride
                        ?? (request120LikeProperties ? 8 : 3)
                    result = try controller.benchmarkSkyLightDisplayStream(
                        displayID: resolvedDisplayID,
                        sampleDuration: sampleDuration,
                        minimumFrameTime: resolvedMinimumFrameTime,
                        queueDepth: resolvedQueueDepth,
                        showCursor: showCursor
                    )
                } else {
                    result = try controller.benchmarkSkyLightDisplayStream(
                        displayID: resolvedDisplayID,
                        sampleDuration: sampleDuration,
                        request120LikeProperties: request120LikeProperties
                    )
                }
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(result)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print(MDKHostBenchmarkFormatter.formatSkyLightDisplayStreamBenchmarkResult(result))
                }
                return result.status == 0 && result.completeFrameCount > 0 ? 0 : 2
            } catch {
                fputs("Failed to run raw SkyLight display stream benchmark: \(error)\n", stderr)
                return 1
            }
        case .benchmark(let displayID, let targetIdentifier, let intent, let processingMode, let json):
            guard let display = resolveDisplay(displayID, controller: controller) else {
                fputs("Unable to resolve a display for the benchmark.\n", stderr)
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
            guard let display = resolveDisplay(displayID, controller: controller) else {
                fputs("Unable to resolve a display for the benchmark matrix.\n", stderr)
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

        if tokens.contains("--experimental-screencapturekit-runtime-inventory") {
            return .screenCaptureKitRuntimeInventory(json: tokens.contains("--json"))
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-proxy-handshake-display",
            tokens: tokens
        ) {
            return .screenCaptureKitProxyHandshakeTrace(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-passive-handshake-display",
            tokens: tokens
        ) {
            return .screenCaptureKitPassiveHandshakeTrace(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-replayd-producer-trace-display",
            tokens: tokens
        ) {
            return .screenCaptureKitReplaydProducerTrace(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-replayd-producer-compare-display",
            tokens: tokens
        ) {
            return .screenCaptureKitReplaydProducerCompare(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-replayd-producer-series-display",
            tokens: tokens
        ) {
            return .screenCaptureKitReplaydProducerSeries(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                windowCount: parseSeriesCount(tokens: tokens) ?? 3,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-replayd-xctrace-display",
            tokens: tokens
        ) {
            return .screenCaptureKitReplaydXctraceArtifacts(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-windowserver-xctrace-display",
            tokens: tokens
        ) {
            return .screenCaptureKitWindowServerXctraceArtifacts(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-screencapturekit-timing-display",
            tokens: tokens
        ) {
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

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-probe-display",
            tokens: tokens
        ) {
            return .privateCaptureProbe(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-probe-hdr"),
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-proxy-probe-display",
            tokens: tokens
        ) {
            return .privateProxyCaptureProbe(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-proxy-probe-hdr"),
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-stream-probe-display",
            tokens: tokens
        ) {
            return .privateDisplayStreamProbe(
                displayID: displayID,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-stream-probe-matrix-display",
            tokens: tokens
        ) {
            return .privateDisplayStreamProbeMatrix(
                displayID: displayID,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-benchmark-display",
            tokens: tokens
        ) {
            return .privateCaptureBenchmark(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-benchmark-hdr"),
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-private-hw-capture-proxy-benchmark-display",
            tokens: tokens
        ) {
            return .privateProxyCaptureBenchmark(
                displayID: displayID,
                requestExtendedRange: tokens.contains("--experimental-private-hw-capture-proxy-benchmark-hdr"),
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                json: tokens.contains("--json")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--experimental-skylight-displaystream-benchmark-display",
            tokens: tokens
        ) {
            return .skyLightDisplayStreamBenchmark(
                displayID: displayID,
                sampleDuration: parseSampleDuration(tokens: tokens) ?? MDKHostBenchmarkController.benchmarkSampleDuration,
                request120LikeProperties: tokens.contains("--request-120-like"),
                minimumFrameTimeOverride: parseMinimumFrameTime(tokens: tokens),
                queueDepthOverride: parseQueueDepth(tokens: tokens),
                showCursor: tokens.contains("--show-cursor"),
                json: tokens.contains("--json"),
                useMetalStimulus: tokens.contains("--with-metal-stimulus")
            )
        }

        if let displayID = parseOptionalDisplayID(
            flag: "--benchmark-matrix-display",
            tokens: tokens
        ) {
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

        guard let targetIndex = tokens.firstIndex(of: "--benchmark-target"),
              tokens.indices.contains(targetIndex + 1) else {
            return nil
        }

        guard let displayID = parseOptionalDisplayID(flag: "--benchmark-display", tokens: tokens) else {
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

    private static func parseSeriesCount(tokens: [String]) -> Int? {
        guard let index = tokens.firstIndex(of: "--series-count"),
              tokens.indices.contains(index + 1),
              let count = Int(tokens[index + 1]),
              count > 0 else {
            return nil
        }

        return count
    }

    private static func parseMinimumFrameTime(tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(of: "--minimum-frame-time"),
              tokens.indices.contains(index + 1),
              let value = Double(tokens[index + 1]),
              value >= 0 else {
            return nil
        }

        return value
    }

    private static func parseQueueDepth(tokens: [String]) -> Int? {
        guard let index = tokens.firstIndex(of: "--queue-depth"),
              tokens.indices.contains(index + 1),
              let value = Int(tokens[index + 1]),
              value > 0 else {
            return nil
        }

        return value
    }

    private static func parseOptionalDisplayID(flag: String, tokens: [String]) -> UInt32?? {
        guard let index = tokens.firstIndex(of: flag) else {
            return nil
        }

        let nextIndex = index + 1
        guard tokens.indices.contains(nextIndex) else {
            return .some(nil)
        }

        let nextToken = tokens[nextIndex]
        if nextToken.hasPrefix("--") {
            return .some(nil)
        }

        let lowered = nextToken.lowercased()
        if lowered == "auto" || lowered == "main" || lowered == "default" {
            return .some(nil)
        }

        guard let displayID = UInt32(nextToken) else {
            return nil
        }

        return .some(displayID)
    }

    private static func resolveDisplay(
        _ displayID: UInt32?,
        controller: MDKHostBenchmarkController
    ) -> MDKDisplayDescriptor? {
        if let displayID {
            return controller.display(id: displayID)
        }

        return controller.defaultDisplay()
    }

    private static func resolveDisplayID(
        _ displayID: UInt32?,
        controller: MDKHostBenchmarkController
    ) throws -> UInt32 {
        guard let resolvedDisplay = resolveDisplay(displayID, controller: controller) else {
            throw NSError(
                domain: "MacDisplayKit.HostCLI",
                code: 64,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve a display for the requested command."]
            )
        }

        return resolvedDisplay.id
    }

    private static func formatScreenCaptureKitRuntimeInventory(
        _ inventory: MDKScreenCaptureKitRuntimeInventory
    ) -> String {
        var lines = inventory.notes

        lines.append("screenCaptureKitSymbols:")
        for name in inventory.screenCaptureKitSymbols.keys.sorted() {
            lines.append("  \(name)=\(inventory.screenCaptureKitSymbols[name] == true ? "true" : "false")")
        }

        lines.append("cmCaptureSymbols:")
        for name in inventory.cmCaptureSymbols.keys.sorted() {
            lines.append("  \(name)=\(inventory.cmCaptureSymbols[name] == true ? "true" : "false")")
        }

        for classInventory in inventory.classes {
            lines.append("class \(classInventory.className) loaded=\(classInventory.loaded ? "true" : "false") methods=\(classInventory.filteredMethodCount)")
            for method in classInventory.filteredMethods {
                lines.append("  \(method)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
