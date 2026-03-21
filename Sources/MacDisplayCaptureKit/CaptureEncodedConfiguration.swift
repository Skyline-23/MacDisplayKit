import CoreVideo
import Foundation

public enum MDKEncodedCaptureBackpressurePolicy: Codable, Equatable, Sendable {
    case unbounded
    case dropOldest(limit: Int)
    case dropNewest(limit: Int)

    var streamBufferingPolicy: AsyncThrowingStream<MDKEncodedFrame, Error>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded:
            return .unbounded
        case .dropOldest(let limit):
            return .bufferingOldest(max(limit, 1))
        case .dropNewest(let limit):
            return .bufferingNewest(max(limit, 1))
        }
    }
}

public struct MDKEncodedCaptureRecoveryPolicy: Codable, Equatable, Sendable {
    public let automaticallyRestartOnFailure: Bool
    public let maximumAutomaticRestartCount: Int
    public let restartDelay: TimeInterval

    public init(
        automaticallyRestartOnFailure: Bool = true,
        maximumAutomaticRestartCount: Int = 2,
        restartDelay: TimeInterval = 0.15
    ) {
        self.automaticallyRestartOnFailure = automaticallyRestartOnFailure
        self.maximumAutomaticRestartCount = max(maximumAutomaticRestartCount, 0)
        self.restartDelay = max(restartDelay, 0)
    }

    public static let disabled = Self(
        automaticallyRestartOnFailure: false,
        maximumAutomaticRestartCount: 0,
        restartDelay: 0
    )
}

public struct MDKEncodedCaptureConfiguration: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let streamConfiguration: MDKSkyLightDisplayStreamConfiguration
    public let codec: MDKVideoEncoderCodec
    public let preprocessStrategy: MDKVideoPreprocessStrategy
    public let targetFrameRate: Int
    public let capturePixelFormat: UInt32?
    public let hdrConfiguration: MDKVideoHDRConfiguration?
    public let backpressurePolicy: MDKEncodedCaptureBackpressurePolicy
    public let recoveryPolicy: MDKEncodedCaptureRecoveryPolicy

    public init(
        displayID: UInt32,
        streamConfiguration: MDKSkyLightDisplayStreamConfiguration = .panelNative(),
        codec: MDKVideoEncoderCodec = .hevc,
        preprocessStrategy: MDKVideoPreprocessStrategy = .none,
        targetFrameRate: Int = 120,
        capturePixelFormat: UInt32? = nil,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        backpressurePolicy: MDKEncodedCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKEncodedCaptureRecoveryPolicy = MDKEncodedCaptureRecoveryPolicy()
    ) {
        self.displayID = displayID
        self.streamConfiguration = streamConfiguration
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.targetFrameRate = max(targetFrameRate, 1)
        self.capturePixelFormat = capturePixelFormat
        self.hdrConfiguration = hdrConfiguration
        self.backpressurePolicy = backpressurePolicy
        self.recoveryPolicy = recoveryPolicy
    }

    public static func panelNative(
        displayID: UInt32,
        queueDepth: Int = 2,
        queueProfile: MDKSkyLightDisplayStreamQueueProfile? = .q2,
        showCursor: Bool = false,
        codec: MDKVideoEncoderCodec = .hevc,
        preprocessStrategy: MDKVideoPreprocessStrategy = .none,
        targetFrameRate: Int = 120,
        capturePixelFormat: UInt32? = nil,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        backpressurePolicy: MDKEncodedCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKEncodedCaptureRecoveryPolicy = MDKEncodedCaptureRecoveryPolicy()
    ) -> Self {
        Self(
            displayID: displayID,
            streamConfiguration: .panelNative(
                queueDepth: queueDepth,
                queueProfile: queueProfile,
                showCursor: showCursor,
                pixelFormat: capturePixelFormat ?? codec.preferredCapturePixelFormat
            ),
            codec: codec,
            preprocessStrategy: preprocessStrategy,
            targetFrameRate: targetFrameRate,
            capturePixelFormat: capturePixelFormat,
            hdrConfiguration: hdrConfiguration,
            backpressurePolicy: backpressurePolicy,
            recoveryPolicy: recoveryPolicy
        )
    }

    var resolvedCapturePixelFormat: UInt32 {
        capturePixelFormat ?? streamConfiguration.pixelFormat ?? codec.preferredCapturePixelFormat
    }
}
