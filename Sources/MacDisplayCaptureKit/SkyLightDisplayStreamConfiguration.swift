import Foundation

public enum MDKSkyLightDisplayStreamQueueProfile: String, Codable, CaseIterable, Sendable {
    case q1
    case q2
    case q3
    case q4

    public var queueDepth: Int {
        switch self {
        case .q1:
            return 1
        case .q2:
            return 2
        case .q3:
            return 3
        case .q4:
            return 4
        }
    }
}

public struct MDKSkyLightDisplayStreamConfiguration: Codable, Equatable, Sendable {
    public let queueDepth: Int
    public let queueProfile: MDKSkyLightDisplayStreamQueueProfile?
    public let showCursor: Bool
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let pixelFormat: UInt32?
    public let yCbCrMatrix: MDKVideoYCbCrMatrix?

    public init(
        queueDepth: Int = 2,
        queueProfile: MDKSkyLightDisplayStreamQueueProfile? = nil,
        showCursor: Bool = false,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        pixelFormat: UInt32? = nil,
        yCbCrMatrix: MDKVideoYCbCrMatrix? = nil
    ) {
        self.queueDepth = queueDepth
        self.queueProfile = queueProfile
        self.showCursor = showCursor
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.pixelFormat = pixelFormat
        self.yCbCrMatrix = yCbCrMatrix
    }

    public static func panelNative(
        queueDepth: Int = 2,
        queueProfile: MDKSkyLightDisplayStreamQueueProfile? = nil,
        showCursor: Bool = false,
        pixelFormat: UInt32? = nil,
        yCbCrMatrix: MDKVideoYCbCrMatrix? = nil
    ) -> Self {
        Self(
            queueDepth: queueDepth,
            queueProfile: queueProfile,
            showCursor: showCursor,
            outputWidth: nil,
            outputHeight: nil,
            pixelFormat: pixelFormat,
            yCbCrMatrix: yCbCrMatrix
        )
    }

    public var resolvedQueueDepth: Int {
        queueProfile?.queueDepth ?? max(queueDepth, 1)
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

    public var resolvedYCbCrMatrixOverride: String? {
        yCbCrMatrix.map { $0.imageBufferValue as String }
    }
}
