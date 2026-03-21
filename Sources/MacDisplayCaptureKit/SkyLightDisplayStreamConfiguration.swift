import Foundation

public struct MDKSkyLightDisplayStreamConfiguration: Codable, Equatable, Sendable {
    public let tuning: MDKSkyLightDisplayStreamTuningCandidate
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let pixelFormat: UInt32?

    public init(
        tuning: MDKSkyLightDisplayStreamTuningCandidate,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        pixelFormat: UInt32? = nil
    ) {
        self.tuning = tuning
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.pixelFormat = pixelFormat
    }

    public static func panelNative(
        tuning: MDKSkyLightDisplayStreamTuningCandidate = MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate,
        pixelFormat: UInt32? = nil
    ) -> Self {
        Self(
            tuning: tuning,
            outputWidth: nil,
            outputHeight: nil,
            pixelFormat: pixelFormat
        )
    }

    public var resolvedMinimumFrameTime: Double {
        max(tuning.minimumFrameTime, 0)
    }

    public var resolvedQueueDepth: Int {
        max(tuning.queueDepth, 1)
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
