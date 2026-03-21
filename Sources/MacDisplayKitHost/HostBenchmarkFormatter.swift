import Foundation
import MacDisplayKit

enum MDKHostBenchmarkFormatter {
    static func formatReplaydXctraceArtifactReport(
        _ report: MDKReplaydXctraceArtifactReport
    ) -> String {
        var lines = formatScreenCaptureKitProxyHandshakeTrace(report.passiveTrace)
            .components(separatedBy: "\n")
        lines.append("")
        lines.append("replayd xctrace artifacts")
        lines.append("PID: \(report.replaydPID)")
        lines.append("Trace directory: \(report.traceDirectoryPath)")
        lines.append("Trace bundle: \(report.tracePath)")
        lines.append("TOC: \(report.tocPath) bytes=\(report.tocByteCount)")
        lines.append("Tables:")
        lines.append(
            "  - \(report.systemCallTable.schema): rows=\(report.systemCallTable.rowCount) bytes=\(report.systemCallTable.byteCount) path=\(report.systemCallTable.outputPath)"
        )
        lines.append(
            "  - \(report.timeSampleTable.schema): rows=\(report.timeSampleTable.rowCount) bytes=\(report.timeSampleTable.byteCount) path=\(report.timeSampleTable.outputPath)"
        )
        lines.append("Unified log: lines=\(report.unifiedLog.lineCount) matched=\(report.unifiedLog.matchedLineCount) path=\(report.unifiedLog.outputPath)")
        if let enqueueFailures = report.unifiedLog.enqueueFailureSummary {
            lines.append(
                "Enqueue failures: count=\(enqueueFailures.eventCount) cadence=\(enqueueFailures.cadenceClassification)"
            )
            if let min = enqueueFailures.minIntervalMilliseconds,
               let max = enqueueFailures.maxIntervalMilliseconds {
                lines.append(String(format: "  interval range: %.3fms..%.3fms", min, max))
            }
            lines.append("  errors: \(enqueueFailures.errorHistogram)")
            lines.append("  opTypes: \(enqueueFailures.operationHistogram)")
            lines.append("  messageKinds: \(enqueueFailures.messageKindHistogram)")
            lines.append("  remoteQueues: \(enqueueFailures.remoteQueueHistogram)")
            if !enqueueFailures.threadHistogram.isEmpty {
                lines.append("  threads: \(enqueueFailures.threadHistogram)")
            }
            if !enqueueFailures.senderProgramCounterHistogram.isEmpty {
                lines.append("  senderPCs: \(enqueueFailures.senderProgramCounterHistogram)")
            }
            if !enqueueFailures.imageOffsetHistogram.isEmpty {
                lines.append("  imageOffsets: \(enqueueFailures.imageOffsetHistogram)")
            }
        }
        if !report.unifiedLog.matchedLines.isEmpty {
            lines.append("Unified log matches:")
            for line in report.unifiedLog.matchedLines {
                lines.append("  - \(line)")
            }
        }
        if !report.notes.isEmpty {
            lines.append("Notes:")
            for note in report.notes {
                lines.append("  - \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func formatReplaydProducerSeriesReport(
        _ report: MDKReplaydProducerTraceSeriesReport
    ) -> String {
        var lines: [String] = []
        lines.append("replayd producer series")
        lines.append("Stimulus: \(report.useMetalStimulus ? "yes" : "no")")
        lines.append("Window count: \(report.traces.count)")
        lines.append("Indicator density summary:")
        for summary in report.summary.indicatorSummaries {
            let windowCounts = summary.windowMatchCounts.map(String.init).joined(separator: ", ")
            lines.append(
                "  - \(summary.name): windows=[\(windowCounts)] total=\(summary.totalMatchCount) peak=\(summary.peakMatchCount) activeWindows=\(summary.nonzeroWindowCount)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func formatReplaydProducerComparisonReport(
        _ report: MDKReplaydProducerComparisonReport
    ) -> String {
        var lines: [String] = []
        lines.append("replayd producer comparison")
        lines.append("")
        lines.append("baseline")
        lines.append(contentsOf: formatReplaydProducerTraceReport(report.baseline).components(separatedBy: "\n"))
        lines.append("")
        lines.append("stimulus")
        lines.append(contentsOf: formatReplaydProducerTraceReport(report.stimulus).components(separatedBy: "\n"))
        lines.append("")
        lines.append("comparison")
        lines.append("Persistent indicators: \(report.comparison.persistentIndicatorNames.isEmpty ? "none" : report.comparison.persistentIndicatorNames.joined(separator: ", "))")
        lines.append("Baseline-only indicators: \(report.comparison.baselineOnlyIndicatorNames.isEmpty ? "none" : report.comparison.baselineOnlyIndicatorNames.joined(separator: ", "))")
        lines.append("Stimulus-only indicators: \(report.comparison.stimulusOnlyIndicatorNames.isEmpty ? "none" : report.comparison.stimulusOnlyIndicatorNames.joined(separator: ", "))")
        lines.append("Indicator match counts:")
        for comparison in report.comparison.indicatorComparisons {
            lines.append("  - \(comparison.name): baseline=\(comparison.baselineMatchCount) stimulus=\(comparison.stimulusMatchCount)")
        }
        return lines.joined(separator: "\n")
    }

    static func formatReplaydProducerTraceReport(
        _ report: MDKReplaydProducerTraceReport
    ) -> String {
        var lines = formatScreenCaptureKitProxyHandshakeTrace(report.passiveTrace)
            .components(separatedBy: "\n")
        lines.append("")
        lines.append("replayd producer sample")
        lines.append("PID: \(report.replaydSample.replaydPID)")
        lines.append(String(format: "Sample duration: %.3fs", report.replaydSample.sampleDuration))
        lines.append("Sample interval: \(report.replaydSample.sampleIntervalMilliseconds)ms")
        lines.append(String(format: "Sample launch delay: %.3fs", report.replaydSampleDelay))
        lines.append("Exit status: \(report.replaydSampleExitStatus)")
        lines.append("Observed producer read queue: \(report.replaydSample.observedProducerReadQueue ? "yes" : "no")")
        lines.append("Observed rqSenderHandleDequeue: \(report.replaydSample.observedRQSenderHandleDequeue ? "yes" : "no")")
        lines.append("Observed FigRemoteQueueSender setup: \(report.replaydSample.observedFigRemoteQueueSenderSetup ? "yes" : "no")")
        lines.append("Observed RPClientProxy capture handler: \(report.replaydSample.observedRPClientProxyCaptureHandler ? "yes" : "no")")
        lines.append("Observed RPClientProxy startRemoteQueue: \(report.replaydSample.observedRPClientProxyStartRemoteQueue ? "yes" : "no")")
        lines.append("Observed SkyLight display stream frame available: \(report.replaydSample.observedSkyLightDisplayStreamFrameAvailable ? "yes" : "no")")
        lines.append("Observed SLContentStream: \(report.replaydSample.observedSLContentStream ? "yes" : "no")")
        if !report.replaydSample.indicators.isEmpty {
            lines.append("Indicators:")
            for indicator in report.replaydSample.indicators where !indicator.matchedLines.isEmpty {
                lines.append("  - \(indicator.name) matches=\(indicator.matchCount)")
                for line in indicator.matchedLines {
                    lines.append("    line: \(line)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func formatScreenCaptureKitProxyHandshakeTrace(
        _ trace: MDKScreenCaptureKitProxyHandshakeTrace
    ) -> String {
        var lines: [String] = []
        lines.append("ScreenCaptureKit proxy handshake trace")
        lines.append("Display ID: \(trace.displayID)")
        lines.append(String(format: "Sample duration: %.3fs", trace.sampleDuration))
        lines.append("Status: \(trace.status)")
        lines.append("Succeeded: \(trace.succeeded ? "yes" : "no")")
        if let streamID = trace.streamID {
            lines.append("Stream ID: \(streamID)")
        }
        if let filterID = trace.filterID {
            lines.append("Filter ID: \(filterID)")
        }
        if !trace.selectors.isEmpty {
            lines.append("Selectors:")
            for selector in trace.selectors {
                lines.append("  - \(selector)")
            }
        }
        if !trace.symbols.isEmpty {
            lines.append("Symbols:")
            for symbol in trace.symbols {
                lines.append("  - \(symbol)")
            }
        }
        if !trace.steps.isEmpty {
            lines.append("Steps:")
            for step in trace.steps {
                var parts = [step.name]
                if let selector = step.selector {
                    parts.append("selector=\(selector)")
                }
                if let symbol = step.symbol {
                    parts.append("symbol=\(symbol)")
                }
                if let status = step.status {
                    parts.append("status=\(status)")
                }
                if let succeeded = step.succeeded {
                    parts.append("succeeded=\(succeeded ? "yes" : "no")")
                }
                lines.append("  - " + parts.joined(separator: " "))
                for note in step.notes {
                    lines.append("    note: \(note)")
                }
            }
        }
        if !trace.notes.isEmpty {
            lines.append("Notes:")
            for note in trace.notes {
                lines.append("  - \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func formatPrivateCaptureBenchmarkResult(
        _ result: MDKPrivateCaptureBenchmarkResult
    ) -> String {
        var lines = formatPrivateCaptureProbeResult(result.probe).components(separatedBy: "\n")
        lines.insert("Private hardware capture benchmark", at: 0)
        lines[1] = "Benchmark base probe"
        lines.append("")
        lines.append(String(format: "Sample duration: %.3fs", result.sampleDuration))
        lines.append("Iterations: \(result.iterationCount)")
        lines.append("Populated frames: \(result.populatedFrameCount)")
        lines.append(String(format: "Observed FPS: %.2f", result.observedFrameRate))
        lines.append(String(format: "Populated FPS: %.2f", result.populatedFrameRate))
        return lines.joined(separator: "\n")
    }

    static func formatPrivateCaptureProbeResult(
        _ result: MDKPrivateCaptureProbeResult
    ) -> String {
        var lines: [String] = []
        lines.append("Private hardware capture probe")
        lines.append("Entry point: \(result.entryPoint.displayName)")
        lines.append("Display ID: \(result.displayID)")
        lines.append("Surface size: \(result.surfaceWidth)x\(result.surfaceHeight)")
        lines.append("Bytes per row: \(result.bytesPerRow)")
        lines.append(String(format: "Pixel format: 0x%08X", result.pixelFormat))
        lines.append(String(format: "Sample word: 0x%08X", result.sampleWord))
        if let captureValue = result.captureValue {
            lines.append(String(format: "Capture value: 0x%08X", captureValue))
        }
        lines.append("Status: \(result.status)")
        lines.append("Surface populated: \(result.surfacePopulated ? "yes" : "no")")
        lines.append("Requested extended range: \(result.requestedExtendedRange ? "yes" : "no")")
        lines.append("Extended range applied: \(result.extendedRangeApplied ? "yes" : "no")")
        if let proxiedFrameAvailable = result.proxiedFrameAvailable {
            lines.append("Proxy frame available: \(proxiedFrameAvailable ? "yes" : "no")")
        }
        if let portStatus = result.portStatus {
            lines.append("Port status: \(portStatus)")
        }
        if let portTypeStatus = result.portTypeStatus {
            lines.append("Port type status: \(portTypeStatus)")
        }
        if let portType = result.portType {
            lines.append(String(format: "Port type: 0x%08X", portType))
        }
        if let portMessageCount = result.portMessageCount {
            lines.append("Port message count: \(portMessageCount)")
        }
        if let portQueueLimit = result.portQueueLimit {
            lines.append("Port queue limit: \(portQueueLimit)")
        }
        if let portSequenceNumber = result.portSequenceNumber {
            lines.append("Port sequence number: \(portSequenceNumber)")
        }
        if let portMessagesWaiting = result.portMessagesWaiting {
            lines.append("Port messages waiting: \(portMessagesWaiting ? "yes" : "no")")
        }
        if let streamPropertiesProfile = result.streamPropertiesProfile {
            lines.append("Stream properties profile: \(streamPropertiesProfile)")
        }
        if let portMode = result.portMode {
            lines.append("Port mode: \(portMode)")
        }
        if let selectiveSharingMode = result.selectiveSharingMode {
            lines.append("Selective sharing mode: \(selectiveSharingMode)")
        }
        if let selectiveSharingHigh = result.selectiveSharingHigh,
           let selectiveSharingLow = result.selectiveSharingLow {
            lines.append(
                String(
                    format: "Selective sharing token: 0x%016llX:0x%016llX",
                    selectiveSharingHigh,
                    selectiveSharingLow
                )
            )
        }
        lines.append("")
        lines.append("Notes:")
        for note in result.notes {
            lines.append("  - \(note)")
        }
        return lines.joined(separator: "\n")
    }

    static func formatPrivateCaptureProbeResults(
        _ results: [MDKPrivateCaptureProbeResult]
    ) -> String {
        results
            .enumerated()
            .map { index, result in
                let header = "Private hardware capture probe #\(index + 1)"
                let body = formatPrivateCaptureProbeResult(result)
                    .components(separatedBy: "\n")
                    .dropFirst()
                    .joined(separator: "\n")
                return header + "\n" + body
            }
            .joined(separator: "\n\n")
    }

    static func formatPrivateCapturePrototypePlan(
        _ plan: MDKPrivateCapturePrototypePlan
    ) -> String {
        var lines: [String] = []
        lines.append("Private hardware capture prototype plan")
        lines.append("Recommended entry point: \(plan.recommendedEntryPoint.displayName)")
        lines.append("Ready for IOSurface prototype: \(plan.readyForIOSurfacePrototype ? "yes" : "no")")
        lines.append("Desktop capture available: \(plan.capabilities.desktopCaptureAvailable ? "yes" : "no")")
        lines.append("Display->IOSurface available: \(plan.capabilities.displayIOSurfaceCaptureAvailable ? "yes" : "no")")
        lines.append("Display->IOSurface+options available: \(plan.capabilities.displayIOSurfaceCaptureWithOptionsAvailable ? "yes" : "no")")
        lines.append("Display->IOSurface proxy available: \(plan.capabilities.displayIOSurfaceProxyCaptureAvailable ? "yes" : "no")")
        lines.append("Display stream proxy available: \(plan.capabilities.displayStreamProxyAvailable ? "yes" : "no")")
        lines.append("Extended range option available: \(plan.capabilities.extendedRangeOptionAvailable ? "yes" : "no")")
        lines.append("")
        lines.append("Notes:")
        for note in plan.recommendedNotes {
            lines.append("  - \(note)")
        }
        return lines.joined(separator: "\n")
    }

    static func formatReport(for suite: MDKCaptureBenchmarkSuiteResult) -> String {
        let assessment = suite.assessment
        var lines: [String] = []
        lines.append("Display: \(suite.plan.display.localizedName) (\(suite.plan.display.id))")
        lines.append("Target: \(suite.plan.target.name)")
        lines.append("Target ID: \(suite.plan.target.identifier)")
        lines.append("Intent: \(suite.plan.intent == .compareBackends ? "compare-backends" : "validate-default-backend")")
        lines.append("Processing path: \(suite.processingMode.rawValue)")
        lines.append("Screen capture access: \(suite.plan.screenCaptureAccessAuthorized ? "authorized" : "not authorized")")
        lines.append("Warmup duration: \(String(format: "%.2fs", suite.warmupDuration))")
        lines.append("Sample duration: \(String(format: "%.2fs", suite.sampleDuration))")
        lines.append("Pixel format: \(String(format: "0x%08X", suite.pixelFormat))")
        lines.append("Suite result: \(assessment.passed ? "PASS" : "FAIL")")
        lines.append(
            String(
                format: "Thresholds: fps>=%.0f%% delivery>=%.0f%% first-frame<=%.0fms",
                suite.plan.target.acceptanceThresholds.minimumObservedFrameRateRatio * 100,
                suite.plan.target.acceptanceThresholds.minimumDeliveryRatio * 100,
                suite.plan.target.acceptanceThresholds.maximumFirstFrameLatency * 1000
            )
        )
        lines.append("")

        for (measurement, measurementAssessment) in zip(suite.measurements, assessment.measurements) {
            lines.append("Backend: \(backendName(measurement.backend))")
            lines.append("Available: \(measurement.available ? "yes" : "no")")
            lines.append("Assessment: \(measurementAssessment.passed ? "PASS" : "FAIL")")
            lines.append("Reason: \(measurement.reason)")
            if let result = measurement.result {
                lines.append("Observed FPS: \(String(format: "%.2f", result.observedFrameRate))")
                lines.append("Delivered frames: \(result.deliveredFrameCount)")
                lines.append("Skipped callbacks: \(result.skippedFrameCount)")
                lines.append("Delivery ratio: \(String(format: "%.3f", result.deliveryRatio))")
                if let firstFrameLatency = result.firstFrameLatency {
                    lines.append("First frame latency: \(String(format: "%.3fs", firstFrameLatency))")
                }
                lines.append("Processed frames: \(result.processedFrameCount)")
                lines.append("Processing failures: \(result.processingFailureCount)")
                lines.append("Processed FPS: \(String(format: "%.2f", result.processedFrameRate))")
                lines.append("Processed ratio: \(String(format: "%.3f", result.processedFrameRatio))")
            }
            lines.append("Summary: \(measurementAssessment.summary)")
            if !measurementAssessment.failedExpectations.isEmpty {
                lines.append("Failed expectations:")
                for expectation in measurementAssessment.failedExpectations {
                    lines.append("  - \(expectation)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func backendName(_ backend: MDKCaptureBackend) -> String {
        switch backend {
        case .avFoundation:
            return "AVFoundation"
        case .cgDisplayStream:
            return "CGDisplayStream"
        @unknown default:
            return "Unknown"
        }
    }
}
