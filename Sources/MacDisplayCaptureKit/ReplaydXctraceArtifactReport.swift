import Foundation

public struct MDKReplaydQueueEnqueueFailureEvent: Codable, Equatable, Sendable {
    public let timestamp: String
    public let remoteQueue: String?
    public let errorCode: Int
    public let operationType: Int
    public let messageKind: String
    public let eventMessage: String

    public init(
        timestamp: String,
        remoteQueue: String?,
        errorCode: Int,
        operationType: Int,
        messageKind: String,
        eventMessage: String
    ) {
        self.timestamp = timestamp
        self.remoteQueue = remoteQueue
        self.errorCode = errorCode
        self.operationType = operationType
        self.messageKind = messageKind
        self.eventMessage = eventMessage
    }
}

public struct MDKReplaydQueueEnqueueFailureSummary: Codable, Equatable, Sendable {
    public let eventCount: Int
    public let remoteQueueHistogram: [String: Int]
    public let errorHistogram: [String: Int]
    public let operationHistogram: [String: Int]
    public let messageKindHistogram: [String: Int]
    public let threadHistogram: [String: Int]
    public let senderProgramCounterHistogram: [String: Int]
    public let imageOffsetHistogram: [String: Int]
    public let minIntervalMilliseconds: Double?
    public let maxIntervalMilliseconds: Double?
    public let intervalHistogram: [String: Int]
    public let cadenceClassification: String
    public let firstEvents: [MDKReplaydQueueEnqueueFailureEvent]

    public init(
        eventCount: Int,
        remoteQueueHistogram: [String: Int],
        errorHistogram: [String: Int],
        operationHistogram: [String: Int],
        messageKindHistogram: [String: Int],
        threadHistogram: [String: Int],
        senderProgramCounterHistogram: [String: Int],
        imageOffsetHistogram: [String: Int],
        minIntervalMilliseconds: Double?,
        maxIntervalMilliseconds: Double?,
        intervalHistogram: [String: Int],
        cadenceClassification: String,
        firstEvents: [MDKReplaydQueueEnqueueFailureEvent]
    ) {
        self.eventCount = eventCount
        self.remoteQueueHistogram = remoteQueueHistogram
        self.errorHistogram = errorHistogram
        self.operationHistogram = operationHistogram
        self.messageKindHistogram = messageKindHistogram
        self.threadHistogram = threadHistogram
        self.senderProgramCounterHistogram = senderProgramCounterHistogram
        self.imageOffsetHistogram = imageOffsetHistogram
        self.minIntervalMilliseconds = minIntervalMilliseconds
        self.maxIntervalMilliseconds = maxIntervalMilliseconds
        self.intervalHistogram = intervalHistogram
        self.cadenceClassification = cadenceClassification
        self.firstEvents = firstEvents
    }
}

public struct MDKReplaydXctraceTableArtifact: Codable, Equatable, Sendable {
    public let schema: String
    public let outputPath: String
    public let byteCount: Int
    public let rowCount: Int
    public let containsRows: Bool
    public let hotSymbolHistogram: [String: Int]
    public let hotSymbolCadenceSummaries: [MDKReplaydXctraceHotSymbolCadenceSummary]
    public let excerpt: [String]

    public init(
        schema: String,
        outputPath: String,
        byteCount: Int,
        rowCount: Int,
        containsRows: Bool,
        hotSymbolHistogram: [String: Int],
        hotSymbolCadenceSummaries: [MDKReplaydXctraceHotSymbolCadenceSummary],
        excerpt: [String]
    ) {
        self.schema = schema
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.rowCount = rowCount
        self.containsRows = containsRows
        self.hotSymbolHistogram = hotSymbolHistogram
        self.hotSymbolCadenceSummaries = hotSymbolCadenceSummaries
        self.excerpt = excerpt
    }
}

public struct MDKReplaydXctraceHotSymbolCadenceSummary: Codable, Equatable, Sendable {
    public let symbolName: String
    public let eventCount: Int
    public let minIntervalMilliseconds: Double?
    public let maxIntervalMilliseconds: Double?
    public let intervalHistogram: [String: Int]
    public let cadenceClassification: String

    public init(
        symbolName: String,
        eventCount: Int,
        minIntervalMilliseconds: Double?,
        maxIntervalMilliseconds: Double?,
        intervalHistogram: [String: Int],
        cadenceClassification: String
    ) {
        self.symbolName = symbolName
        self.eventCount = eventCount
        self.minIntervalMilliseconds = minIntervalMilliseconds
        self.maxIntervalMilliseconds = maxIntervalMilliseconds
        self.intervalHistogram = intervalHistogram
        self.cadenceClassification = cadenceClassification
    }
}

public struct MDKReplaydUnifiedLogArtifact: Codable, Equatable, Sendable {
    public let outputPath: String
    public let byteCount: Int
    public let lineCount: Int
    public let matchedLineCount: Int
    public let matchedLines: [String]
    public let enqueueFailureSummary: MDKReplaydQueueEnqueueFailureSummary?

    public init(
        outputPath: String,
        byteCount: Int,
        lineCount: Int,
        matchedLineCount: Int,
        matchedLines: [String],
        enqueueFailureSummary: MDKReplaydQueueEnqueueFailureSummary?
    ) {
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.matchedLineCount = matchedLineCount
        self.matchedLines = matchedLines
        self.enqueueFailureSummary = enqueueFailureSummary
    }
}

public enum MDKReplaydXctraceArtifactParser {
    private struct HotSymbolPattern {
        let name: String
        let expression: String
    }

    private static let hotSymbolPatterns: [HotSymbolPattern] = [
        HotSymbolPattern(name: "rqSenderHandleDequeue", expression: #"rqSenderHandleDequeue"#),
        HotSymbolPattern(
            name: "FigRemoteQueueSenderResetIfFullAndEnqueueSequence",
            expression: #"FigRemoteQueueSenderResetIfFullAndEnqueueSequence"#
        ),
        HotSymbolPattern(name: "roEnqueueSampleBuffer", expression: #"roEnqueueSampleBuffer"#),
        HotSymbolPattern(name: "roEnqueue", expression: #"name=\"roEnqueue\""#),
        HotSymbolPattern(
            name: "CGYDisplayStreamFrameAvailable",
            expression: #"CGYDisplayStreamNotification_server|_CGYDisplayStreamFrameAvailable"#
        ),
        HotSymbolPattern(name: "SLContentStream", expression: #"SLContentStream"#)
    ]

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    private static let enqueueFailureExpression = try? NSRegularExpression(
        pattern: #"_SCRemoteQueue_Enqueue:\d+\s+remoteQueue=(0x[0-9a-fA-F]+)\s+err=(-?\d+)\s+opType=(\d+)\s+(Client terminated the queue|Queue is full!|Error occurred when enqueuing data)"#
    )
    private static let timestampExpression = try? NSRegularExpression(
        pattern: #""timestamp":"([^"]+)""#
    )
    private static let threadIDExpression = try? NSRegularExpression(
        pattern: #""threadID":(\d+)"#
    )
    private static let senderProgramCounterExpression = try? NSRegularExpression(
        pattern: #""senderProgramCounter":(\d+)"#
    )
    private static let imageOffsetExpression = try? NSRegularExpression(
        pattern: #""imageOffset":(\d+)"#
    )
    private static let rowExpression = try? NSRegularExpression(
        pattern: #"(?s)<row>(.*?)</row>"#
    )
    private static let rowStartTimeExpression = try? NSRegularExpression(
        pattern: #"<start-time[^>]*>(\d+)</start-time>|<sample-time[^>]*>(\d+)</sample-time>"#
    )

    public static func summarizeTableArtifact(
        schema: String,
        outputPath: String,
        exportText: String
    ) -> MDKReplaydXctraceTableArtifact {
        let excerpt = exportText
            .split(whereSeparator: \.isNewline)
            .prefix(8)
            .map(String.init)
        let rowCount = exportText.components(separatedBy: "<row").count - 1
        let hotSymbolHistogram = summarizeHotSymbols(in: exportText)
        let hotSymbolCadenceSummaries = summarizeHotSymbolCadences(in: exportText)

        return MDKReplaydXctraceTableArtifact(
            schema: schema,
            outputPath: outputPath,
            byteCount: exportText.lengthOfBytes(using: .utf8),
            rowCount: max(0, rowCount),
            containsRows: rowCount > 0,
            hotSymbolHistogram: hotSymbolHistogram,
            hotSymbolCadenceSummaries: hotSymbolCadenceSummaries,
            excerpt: excerpt
        )
    }

    public static func summarizeUnifiedLogArtifact(
        outputPath: String,
        logText: String
    ) -> MDKReplaydUnifiedLogArtifact {
        let lines = logText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let interestingLines = lines.filter {
            $0.range(
                of: "SCCapture|SCScreenCaptureSession|captureScreenshot|screenAttribution|TCC Allow|Health: captureSession|SLContentStream|remotequeue|startRemoteQueue|_SCRemoteQueue_Enqueue",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
        let enqueueFailureSummary = summarizeEnqueueFailures(in: interestingLines)

        return MDKReplaydUnifiedLogArtifact(
            outputPath: outputPath,
            byteCount: logText.lengthOfBytes(using: .utf8),
            lineCount: lines.count,
            matchedLineCount: interestingLines.count,
            matchedLines: Array(interestingLines.prefix(20)),
            enqueueFailureSummary: enqueueFailureSummary
        )
    }

    private static func summarizeEnqueueFailures(
        in lines: [String]
    ) -> MDKReplaydQueueEnqueueFailureSummary? {
        let events = lines.compactMap(parseEnqueueFailureEvent(from:))
        guard !events.isEmpty else {
            return nil
        }

        var remoteQueueHistogram: [String: Int] = [:]
        var errorHistogram: [String: Int] = [:]
        var operationHistogram: [String: Int] = [:]
        var messageKindHistogram: [String: Int] = [:]
        var threadHistogram: [String: Int] = [:]
        var senderProgramCounterHistogram: [String: Int] = [:]
        var imageOffsetHistogram: [String: Int] = [:]
        var intervals: [Double] = []

        for event in events {
            let remoteQueueKey = event.remoteQueue ?? "<unknown>"
            remoteQueueHistogram[remoteQueueKey, default: 0] += 1
            errorHistogram[String(event.errorCode), default: 0] += 1
            operationHistogram[String(event.operationType), default: 0] += 1
            messageKindHistogram[event.messageKind, default: 0] += 1
            if let threadID = parseMetadataValue(using: threadIDExpression, from: event.eventMessage) {
                threadHistogram[threadID, default: 0] += 1
            }
            if let senderProgramCounter = parseMetadataValue(using: senderProgramCounterExpression, from: event.eventMessage) {
                senderProgramCounterHistogram[senderProgramCounter, default: 0] += 1
            }
            if let imageOffset = parseMetadataValue(using: imageOffsetExpression, from: event.eventMessage) {
                imageOffsetHistogram[imageOffset, default: 0] += 1
            }
        }

        for pair in zip(events, events.dropFirst()) {
            guard
                let previousDate = parseLogTimestamp(pair.0.timestamp),
                let currentDate = parseLogTimestamp(pair.1.timestamp)
            else {
                continue
            }
            intervals.append(currentDate.timeIntervalSince(previousDate) * 1000.0)
        }

        let intervalHistogram = histogram(for: intervals)
        let cadenceClassification = classifyCadence(intervals)

        return MDKReplaydQueueEnqueueFailureSummary(
            eventCount: events.count,
            remoteQueueHistogram: remoteQueueHistogram,
            errorHistogram: errorHistogram,
            operationHistogram: operationHistogram,
            messageKindHistogram: messageKindHistogram,
            threadHistogram: threadHistogram,
            senderProgramCounterHistogram: senderProgramCounterHistogram,
            imageOffsetHistogram: imageOffsetHistogram,
            minIntervalMilliseconds: intervals.min(),
            maxIntervalMilliseconds: intervals.max(),
            intervalHistogram: intervalHistogram,
            cadenceClassification: cadenceClassification,
            firstEvents: Array(events.prefix(12))
        )
    }

    private static func parseEnqueueFailureEvent(from line: String) -> MDKReplaydQueueEnqueueFailureEvent? {
        guard
            let expression = enqueueFailureExpression,
            let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            )
        else {
            return nil
        }

        let timestamp: String
        if
            let timestampExpression,
            let timestampMatch = timestampExpression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            )
        {
            timestamp = captureGroup(at: 1, from: timestampMatch, in: line) ?? ""
        } else {
            timestamp = ""
        }

        let remoteQueue = captureGroup(at: 1, from: match, in: line)
        let errorCode = Int(captureGroup(at: 2, from: match, in: line) ?? "") ?? 0
        let operationType = Int(captureGroup(at: 3, from: match, in: line) ?? "") ?? 0
        let messageKind = classifyEnqueueMessageKind(captureGroup(at: 4, from: match, in: line) ?? "")

        return MDKReplaydQueueEnqueueFailureEvent(
            timestamp: timestamp,
            remoteQueue: remoteQueue,
            errorCode: errorCode,
            operationType: operationType,
            messageKind: messageKind,
            eventMessage: line
        )
    }

    private static func captureGroup(
        at index: Int,
        from match: NSTextCheckingResult,
        in source: String
    ) -> String? {
        guard
            index < match.numberOfRanges,
            let range = Range(match.range(at: index), in: source)
        else {
            return nil
        }
        return String(source[range])
    }

    private static func parseLogTimestamp(_ timestamp: String) -> Date? {
        guard !timestamp.isEmpty else {
            return nil
        }
        return logTimestampFormatter.date(from: timestamp)
    }

    private static func parseMetadataValue(
        using expression: NSRegularExpression?,
        from line: String
    ) -> String? {
        guard
            let expression,
            let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            )
        else {
            return nil
        }
        return captureGroup(at: 1, from: match, in: line)
    }

    private static func histogram(for values: [Double]) -> [String: Int] {
        var histogram: [String: Int] = [:]
        for value in values {
            let rounded = (value * 10.0).rounded() / 10.0
            histogram[String(format: "%.1fms", rounded), default: 0] += 1
        }
        return histogram
    }

    private static func classifyCadence(_ intervals: [Double]) -> String {
        guard intervals.count >= 2 else {
            return "insufficient-data"
        }

        let count120Like = intervals.filter { $0 <= 10.0 }.count
        let count60Like = intervals.filter { $0 >= 12.0 && $0 <= 21.0 }.count
        let total = intervals.count

        if Double(count120Like) / Double(total) >= 0.7 {
            return "120hz-like"
        }
        if Double(count60Like) / Double(total) >= 0.7 {
            return "60hz-like"
        }
        return "coalesced-or-mixed"
    }

    private static func classifyEnqueueMessageKind(_ message: String) -> String {
        switch message {
        case "Client terminated the queue":
            return "client-terminated"
        case "Queue is full!":
            return "queue-full"
        case "Error occurred when enqueuing data":
            return "generic-enqueue-error"
        default:
            return "unknown"
        }
    }

    private static func summarizeHotSymbols(in exportText: String) -> [String: Int] {
        var histogram: [String: Int] = [:]
        for pattern in hotSymbolPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern.expression) else {
                continue
            }
            let range = NSRange(exportText.startIndex..<exportText.endIndex, in: exportText)
            let count = expression.numberOfMatches(in: exportText, range: range)
            if count > 0 {
                histogram[pattern.name] = count
            }
        }
        return histogram
    }

    private static func summarizeHotSymbolCadences(
        in exportText: String
    ) -> [MDKReplaydXctraceHotSymbolCadenceSummary] {
        guard
            let rowExpression,
            let rowStartTimeExpression
        else {
            return []
        }

        let exportRange = NSRange(exportText.startIndex..<exportText.endIndex, in: exportText)
        let rowMatches = rowExpression.matches(in: exportText, range: exportRange)
        guard !rowMatches.isEmpty else {
            return []
        }

        var symbolTimestamps: [String: [Double]] = [:]

        for rowMatch in rowMatches {
            guard
                let rowRange = Range(rowMatch.range(at: 1), in: exportText)
            else {
                continue
            }
            let rowText = String(exportText[rowRange])
            guard let timestamp = parseRowTimestamp(rowText, using: rowStartTimeExpression) else {
                continue
            }

            for pattern in hotSymbolPatterns {
                guard let expression = try? NSRegularExpression(pattern: pattern.expression) else {
                    continue
                }
                let rowTextRange = NSRange(rowText.startIndex..<rowText.endIndex, in: rowText)
                if expression.firstMatch(in: rowText, range: rowTextRange) != nil {
                    symbolTimestamps[pattern.name, default: []].append(timestamp)
                }
            }
        }

        return hotSymbolPatterns.compactMap { pattern in
            guard let timestamps = symbolTimestamps[pattern.name], !timestamps.isEmpty else {
                return nil
            }
            let sorted = timestamps.sorted()
            let intervals = zip(sorted, sorted.dropFirst()).map { ($1 - $0) / 1_000_000.0 }
            return MDKReplaydXctraceHotSymbolCadenceSummary(
                symbolName: pattern.name,
                eventCount: sorted.count,
                minIntervalMilliseconds: intervals.min(),
                maxIntervalMilliseconds: intervals.max(),
                intervalHistogram: histogram(for: intervals),
                cadenceClassification: classifyCadence(intervals)
            )
        }
    }

    private static func parseRowTimestamp(
        _ rowText: String,
        using expression: NSRegularExpression
    ) -> Double? {
        guard
            let match = expression.firstMatch(
                in: rowText,
                range: NSRange(rowText.startIndex..<rowText.endIndex, in: rowText)
            )
        else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            if let value = captureGroup(at: index, from: match, in: rowText),
               let timestamp = Double(value) {
                return timestamp
            }
        }
        return nil
    }
}
