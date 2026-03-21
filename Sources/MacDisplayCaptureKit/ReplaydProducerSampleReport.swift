import Foundation

public struct MDKReplaydProducerSampleIndicator: Codable, Equatable, Sendable {
    public let name: String
    public let pattern: String
    public let matchCount: Int
    public let matchedLines: [String]

    public init(
        name: String,
        pattern: String,
        matchCount: Int,
        matchedLines: [String]
    ) {
        self.name = name
        self.pattern = pattern
        self.matchCount = matchCount
        self.matchedLines = matchedLines
    }
}

public struct MDKReplaydProducerSampleReport: Codable, Equatable, Sendable {
    public let replaydPID: Int32
    public let sampleDuration: TimeInterval
    public let sampleIntervalMilliseconds: Int
    public let totalLineCount: Int
    public let observedProducerReadQueue: Bool
    public let observedRQSenderHandleDequeue: Bool
    public let observedFigRemoteQueueSenderSetup: Bool
    public let observedRPClientProxyCaptureHandler: Bool
    public let observedRPClientProxyStartRemoteQueue: Bool
    public let observedSkyLightDisplayStreamFrameAvailable: Bool
    public let observedSLContentStream: Bool
    public let indicators: [MDKReplaydProducerSampleIndicator]

    public init(
        replaydPID: Int32,
        sampleDuration: TimeInterval,
        sampleIntervalMilliseconds: Int,
        totalLineCount: Int,
        observedProducerReadQueue: Bool,
        observedRQSenderHandleDequeue: Bool,
        observedFigRemoteQueueSenderSetup: Bool,
        observedRPClientProxyCaptureHandler: Bool,
        observedRPClientProxyStartRemoteQueue: Bool,
        observedSkyLightDisplayStreamFrameAvailable: Bool,
        observedSLContentStream: Bool,
        indicators: [MDKReplaydProducerSampleIndicator]
    ) {
        self.replaydPID = replaydPID
        self.sampleDuration = sampleDuration
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        self.totalLineCount = totalLineCount
        self.observedProducerReadQueue = observedProducerReadQueue
        self.observedRQSenderHandleDequeue = observedRQSenderHandleDequeue
        self.observedFigRemoteQueueSenderSetup = observedFigRemoteQueueSenderSetup
        self.observedRPClientProxyCaptureHandler = observedRPClientProxyCaptureHandler
        self.observedRPClientProxyStartRemoteQueue = observedRPClientProxyStartRemoteQueue
        self.observedSkyLightDisplayStreamFrameAvailable = observedSkyLightDisplayStreamFrameAvailable
        self.observedSLContentStream = observedSLContentStream
        self.indicators = indicators
    }
}

public struct MDKReplaydProducerIndicatorComparison: Codable, Equatable, Sendable {
    public let name: String
    public let baselineObserved: Bool
    public let stimulusObserved: Bool
    public let baselineMatchCount: Int
    public let stimulusMatchCount: Int

    public init(
        name: String,
        baselineObserved: Bool,
        stimulusObserved: Bool,
        baselineMatchCount: Int,
        stimulusMatchCount: Int
    ) {
        self.name = name
        self.baselineObserved = baselineObserved
        self.stimulusObserved = stimulusObserved
        self.baselineMatchCount = baselineMatchCount
        self.stimulusMatchCount = stimulusMatchCount
    }
}

public struct MDKReplaydProducerSampleComparison: Codable, Equatable, Sendable {
    public let persistentIndicatorNames: [String]
    public let baselineOnlyIndicatorNames: [String]
    public let stimulusOnlyIndicatorNames: [String]
    public let indicatorComparisons: [MDKReplaydProducerIndicatorComparison]

    public init(
        persistentIndicatorNames: [String],
        baselineOnlyIndicatorNames: [String],
        stimulusOnlyIndicatorNames: [String],
        indicatorComparisons: [MDKReplaydProducerIndicatorComparison]
    ) {
        self.persistentIndicatorNames = persistentIndicatorNames
        self.baselineOnlyIndicatorNames = baselineOnlyIndicatorNames
        self.stimulusOnlyIndicatorNames = stimulusOnlyIndicatorNames
        self.indicatorComparisons = indicatorComparisons
    }
}

public struct MDKReplaydProducerIndicatorSeriesSummary: Codable, Equatable, Sendable {
    public let name: String
    public let windowMatchCounts: [Int]
    public let totalMatchCount: Int
    public let peakMatchCount: Int
    public let nonzeroWindowCount: Int

    public init(
        name: String,
        windowMatchCounts: [Int],
        totalMatchCount: Int,
        peakMatchCount: Int,
        nonzeroWindowCount: Int
    ) {
        self.name = name
        self.windowMatchCounts = windowMatchCounts
        self.totalMatchCount = totalMatchCount
        self.peakMatchCount = peakMatchCount
        self.nonzeroWindowCount = nonzeroWindowCount
    }
}

public struct MDKReplaydProducerSampleSeriesSummary: Codable, Equatable, Sendable {
    public let windowCount: Int
    public let indicatorSummaries: [MDKReplaydProducerIndicatorSeriesSummary]

    public init(
        windowCount: Int,
        indicatorSummaries: [MDKReplaydProducerIndicatorSeriesSummary]
    ) {
        self.windowCount = windowCount
        self.indicatorSummaries = indicatorSummaries
    }
}

public enum MDKReplaydProducerSampleParser {
    private struct Pattern {
        let name: String
        let expression: String
    }

    private static let patterns: [Pattern] = [
        Pattern(
            name: "producer-read-queue",
            expression: #"rqSenderHandleDequeue|com\.apple\.coremedia\.remotequeue_sender\.readqueue"#
        ),
        Pattern(
            name: "fig-remote-queue-sender-setup",
            expression: #"FigRemoteQueueSender(Create|CreateXPCObject|SetMaximumBufferAge)|SCRemoteQueue_(CreateSenderQueue|StartSenderQueue|EnqueueSampleBuffer|_Enqueue)"#
        ),
        Pattern(
            name: "rpclient-capture-handler",
            expression: #"RPClientProxy.*captureHandlerWithSample:timingData:"#
        ),
        Pattern(
            name: "rpclient-start-remote-queue",
            expression: #"RPClientProxy.*startRemoteQueue:streamID:"#
        ),
        Pattern(
            name: "skylight-display-stream",
            expression: #"CGYDisplayStreamNotification_server|_CGYDisplayStreamFrameAvailable"#
        ),
        Pattern(
            name: "slcontentstream",
            expression: #"SLContentStream"#
        )
    ]

    public static func analyze(
        sampleText: String,
        replaydPID: Int32,
        sampleDuration: TimeInterval,
        sampleIntervalMilliseconds: Int
    ) -> MDKReplaydProducerSampleReport {
        let lines = sampleText
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        let indicators = patterns.map { pattern in
            let expression = try? NSRegularExpression(pattern: pattern.expression)
            let analysis = matchAnalysis(in: lines, using: expression)
            return MDKReplaydProducerSampleIndicator(
                name: pattern.name,
                pattern: pattern.expression,
                matchCount: analysis.matchCount,
                matchedLines: analysis.uniqueLines
            )
        }

        func observed(_ name: String) -> Bool {
            indicators.first(where: { $0.name == name })?.matchedLines.isEmpty == false
        }

        return MDKReplaydProducerSampleReport(
            replaydPID: replaydPID,
            sampleDuration: sampleDuration,
            sampleIntervalMilliseconds: sampleIntervalMilliseconds,
            totalLineCount: lines.count,
            observedProducerReadQueue: observed("producer-read-queue"),
            observedRQSenderHandleDequeue: lines.contains(where: { $0.contains("rqSenderHandleDequeue") }),
            observedFigRemoteQueueSenderSetup: observed("fig-remote-queue-sender-setup"),
            observedRPClientProxyCaptureHandler: observed("rpclient-capture-handler"),
            observedRPClientProxyStartRemoteQueue: observed("rpclient-start-remote-queue"),
            observedSkyLightDisplayStreamFrameAvailable: observed("skylight-display-stream"),
            observedSLContentStream: observed("slcontentstream"),
            indicators: indicators
        )
    }

    private static func matchAnalysis(
        in lines: [String],
        using expression: NSRegularExpression?
    ) -> (matchCount: Int, uniqueLines: [String]) {
        guard let expression else {
            return (0, [])
        }

        var matchedLines: [String] = []
        var seen = Set<String>()
        var matchCount = 0
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard expression.firstMatch(in: line, range: range) != nil else {
                continue
            }
            matchCount += 1
            if seen.insert(line).inserted {
                matchedLines.append(line)
            }
        }

        return (matchCount, matchedLines)
    }
}

public enum MDKReplaydProducerSampleComparator {
    public static func compare(
        baseline: MDKReplaydProducerSampleReport,
        stimulus: MDKReplaydProducerSampleReport
    ) -> MDKReplaydProducerSampleComparison {
        let baselineMatches = Dictionary(
            uniqueKeysWithValues: baseline.indicators.map { ($0.name, !$0.matchedLines.isEmpty) }
        )
        let stimulusMatches = Dictionary(
            uniqueKeysWithValues: stimulus.indicators.map { ($0.name, !$0.matchedLines.isEmpty) }
        )
        let baselineMatchCounts = Dictionary(
            uniqueKeysWithValues: baseline.indicators.map { ($0.name, $0.matchCount) }
        )
        let stimulusMatchCounts = Dictionary(
            uniqueKeysWithValues: stimulus.indicators.map { ($0.name, $0.matchCount) }
        )

        var orderedNames: [String] = []
        var seenNames = Set<String>()
        for name in baseline.indicators.map(\.name) + stimulus.indicators.map(\.name) where seenNames.insert(name).inserted {
            orderedNames.append(name)
        }

        let comparisons = orderedNames.map { name in
            MDKReplaydProducerIndicatorComparison(
                name: name,
                baselineObserved: baselineMatches[name] ?? false,
                stimulusObserved: stimulusMatches[name] ?? false,
                baselineMatchCount: baselineMatchCounts[name] ?? 0,
                stimulusMatchCount: stimulusMatchCounts[name] ?? 0
            )
        }

        let persistent = comparisons
            .filter { $0.baselineObserved && $0.stimulusObserved }
            .map(\.name)
        let baselineOnly = comparisons
            .filter { $0.baselineObserved && !$0.stimulusObserved }
            .map(\.name)
        let stimulusOnly = comparisons
            .filter { !$0.baselineObserved && $0.stimulusObserved }
            .map(\.name)

        return MDKReplaydProducerSampleComparison(
            persistentIndicatorNames: persistent,
            baselineOnlyIndicatorNames: baselineOnly,
            stimulusOnlyIndicatorNames: stimulusOnly,
            indicatorComparisons: comparisons
        )
    }
}

public enum MDKReplaydProducerSampleSeriesAnalyzer {
    public static func summarize(
        reports: [MDKReplaydProducerSampleReport]
    ) -> MDKReplaydProducerSampleSeriesSummary {
        var orderedNames: [String] = []
        var seenNames = Set<String>()
        for name in reports.flatMap({ $0.indicators.map(\.name) }) where seenNames.insert(name).inserted {
            orderedNames.append(name)
        }

        let summaries = orderedNames.map { name in
            let windowCounts = reports.map { report in
                report.indicators.first(where: { $0.name == name })?.matchCount ?? 0
            }
            return MDKReplaydProducerIndicatorSeriesSummary(
                name: name,
                windowMatchCounts: windowCounts,
                totalMatchCount: windowCounts.reduce(0, +),
                peakMatchCount: windowCounts.max() ?? 0,
                nonzeroWindowCount: windowCounts.filter { $0 > 0 }.count
            )
        }

        return MDKReplaydProducerSampleSeriesSummary(
            windowCount: reports.count,
            indicatorSummaries: summaries
        )
    }
}
