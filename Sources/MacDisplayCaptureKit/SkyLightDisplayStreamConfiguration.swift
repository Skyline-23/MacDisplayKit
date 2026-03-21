import Foundation

public struct MDKSkyLightDisplayStreamConfiguration: Codable, Equatable, Sendable {
    public let queueDepth: Int
    public let showCursor: Bool
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let pixelFormat: UInt32?

    public init(
        queueDepth: Int = 2,
        showCursor: Bool = false,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        pixelFormat: UInt32? = nil
    ) {
        self.queueDepth = queueDepth
        self.showCursor = showCursor
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.pixelFormat = pixelFormat
    }

    public static func panelNative(
        queueDepth: Int = 2,
        showCursor: Bool = false,
        pixelFormat: UInt32? = nil
    ) -> Self {
        Self(
            queueDepth: queueDepth,
            showCursor: showCursor,
            outputWidth: nil,
            outputHeight: nil,
            pixelFormat: pixelFormat
        )
    }

    public var resolvedQueueDepth: Int {
        max(queueDepth, 1)
    }

    public var resolvedShowCursor: Bool {
        showCursor
    }

    public var resolvedOutputWidth: Int {
        max(outputWidth ?? 0, 0)
    }

    public var resolvedOutputHeight: Int {
        max(outputHeight ?? 0, 0)
    }

    public var resolvedPixelFormatOverride: UInt32 {
        pixelFormat ?? 0
    }
}
