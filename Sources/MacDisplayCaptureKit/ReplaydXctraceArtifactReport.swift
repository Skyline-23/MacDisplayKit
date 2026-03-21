import Foundation

public struct MDKReplaydXctraceTableArtifact: Codable, Equatable, Sendable {
    public let schema: String
    public let outputPath: String
    public let byteCount: Int
    public let rowCount: Int
    public let containsRows: Bool
    public let excerpt: [String]

    public init(
        schema: String,
        outputPath: String,
        byteCount: Int,
        rowCount: Int,
        containsRows: Bool,
        excerpt: [String]
    ) {
        self.schema = schema
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.rowCount = rowCount
        self.containsRows = containsRows
        self.excerpt = excerpt
    }
}

public struct MDKReplaydUnifiedLogArtifact: Codable, Equatable, Sendable {
    public let outputPath: String
    public let byteCount: Int
    public let lineCount: Int
    public let matchedLineCount: Int
    public let matchedLines: [String]

    public init(
        outputPath: String,
        byteCount: Int,
        lineCount: Int,
        matchedLineCount: Int,
        matchedLines: [String]
    ) {
        self.outputPath = outputPath
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.matchedLineCount = matchedLineCount
        self.matchedLines = matchedLines
    }
}

public enum MDKReplaydXctraceArtifactParser {
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

        return MDKReplaydXctraceTableArtifact(
            schema: schema,
            outputPath: outputPath,
            byteCount: exportText.lengthOfBytes(using: .utf8),
            rowCount: max(0, rowCount),
            containsRows: rowCount > 0,
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
                of: "SCCapture|SCScreenCaptureSession|captureScreenshot|screenAttribution|TCC Allow|Health: captureSession|SLContentStream|remotequeue|startRemoteQueue",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }

        return MDKReplaydUnifiedLogArtifact(
            outputPath: outputPath,
            byteCount: logText.lengthOfBytes(using: .utf8),
            lineCount: lines.count,
            matchedLineCount: interestingLines.count,
            matchedLines: Array(interestingLines.prefix(20))
        )
    }
}
