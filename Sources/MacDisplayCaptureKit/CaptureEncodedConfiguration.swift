import CoreVideo
import Foundation

public enum MDKEncodedCaptureDeliveryMode: String, Codable, Equatable, Sendable {
    case multiplexed
    case callbackOnly = "callback-only"
}

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

public enum MDKEncodedCaptureEncoderInputStrategy: String, Codable, Equatable, Sendable {
    case auto
    case bgra
    case yuv420v8 = "420v8"
    case yuv420v10 = "420v10"
}

public struct MDKEncodedCaptureConfiguration: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let streamConfiguration: MDKSkyLightDisplayStreamConfiguration
    public let codec: MDKVideoEncoderCodec
    public let preprocessStrategy: MDKVideoPreprocessStrategy
    public let targetFrameRate: Int
    public let deliveryMode: MDKEncodedCaptureDeliveryMode
    public let capturePixelFormat: UInt32?
    public let encoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy
    public let hdrConfiguration: MDKVideoHDRConfiguration?
    public let backpressurePolicy: MDKEncodedCaptureBackpressurePolicy
    public let recoveryPolicy: MDKEncodedCaptureRecoveryPolicy

    public init(
        displayID: UInt32,
        streamConfiguration: MDKSkyLightDisplayStreamConfiguration = .panelNative(),
        codec: MDKVideoEncoderCodec = .hevc,
        preprocessStrategy: MDKVideoPreprocessStrategy = .none,
        targetFrameRate: Int = 120,
        deliveryMode: MDKEncodedCaptureDeliveryMode = .multiplexed,
        capturePixelFormat: UInt32? = nil,
        encoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy = .auto,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        backpressurePolicy: MDKEncodedCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKEncodedCaptureRecoveryPolicy = MDKEncodedCaptureRecoveryPolicy()
    ) {
        self.displayID = displayID
        self.streamConfiguration = streamConfiguration
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.targetFrameRate = max(targetFrameRate, 1)
        self.deliveryMode = deliveryMode
        self.capturePixelFormat = capturePixelFormat
        self.encoderInputStrategy = encoderInputStrategy
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
        deliveryMode: MDKEncodedCaptureDeliveryMode = .multiplexed,
        capturePixelFormat: UInt32? = nil,
        encoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy = .auto,
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
            deliveryMode: deliveryMode,
            capturePixelFormat: capturePixelFormat,
            encoderInputStrategy: encoderInputStrategy,
            hdrConfiguration: hdrConfiguration,
            backpressurePolicy: backpressurePolicy,
            recoveryPolicy: recoveryPolicy
        )
    }

    var resolvedCapturePixelFormat: UInt32 {
        capturePixelFormat ?? streamConfiguration.pixelFormat ?? codec.preferredCapturePixelFormat
    }

    var resolvedSourceBackend: MDKEncodedCaptureSourceBackend {
        resolvedSourceBackend(using: MDKPrivateCaptureCapabilityProbe.current())
    }

    func resolvedSourceBackend(
        using capabilities: MDKPrivateCaptureCapabilities
    ) -> MDKEncodedCaptureSourceBackend {
        guard shouldPreferPrivateIOSurfaceSource(using: capabilities) else {
            return .skyLightDisplayStream
        }

        if capabilities.displayIOSurfaceCaptureWithOptionsAvailable ||
            capabilities.displayIOSurfaceCaptureAvailable {
            return .privateDirectIOSurface
        }

        return .skyLightDisplayStream
    }

    var resolvedPrivateCaptureSurfaceCount: Int {
        let width = max(streamConfiguration.resolvedOutputWidth, 1)
        let height = max(streamConfiguration.resolvedOutputHeight, 1)
        let estimatedSurfaceBytes = width * height * 4
        if estimatedSurfaceBytes >= 20_000_000 {
            return targetFrameRate >= 100 ? 8 : 6
        }
        return targetFrameRate >= 100 ? 10 : 6
    }

    var resolvedEncodedHDRConfiguration: MDKVideoHDRConfiguration? {
        resolvedEncodedHDRConfiguration(using: MDKPrivateCaptureCapabilityProbe.current())
    }

    func resolvedEncodedHDRConfiguration(
        using capabilities: MDKPrivateCaptureCapabilities
    ) -> MDKVideoHDRConfiguration? {
        guard let negotiatedConfiguration = hdrConfiguration?.negotiatedForEncodedDelivery(codec: codec) else {
            return nil
        }

        guard resolvedSourceBackend(using: capabilities) == .privateDirectIOSurface,
              negotiatedConfiguration.transferFunction != .ituR709 else {
            return negotiatedConfiguration
        }

        // The private direct path still captures the negotiated display output.
        // Preserve the negotiated source primaries so the BGRA->YCbCr converter
        // can map display P3 sources into the BT.2020 HDR signal container.
        return MDKVideoHDRConfiguration(
            sourceColorPrimaries: negotiatedConfiguration.sourceColorPrimaries,
            colorPrimaries: negotiatedConfiguration.colorPrimaries,
            transferFunction: negotiatedConfiguration.transferFunction,
            yCbCrMatrix: negotiatedConfiguration.yCbCrMatrix,
            metadataInsertionMode: negotiatedConfiguration.metadataInsertionMode,
            masteringDisplayColorVolume: negotiatedConfiguration.masteringDisplayColorVolume,
            contentLightLevelInfo: negotiatedConfiguration.contentLightLevelInfo
        )
    }

    private func shouldPreferPrivateIOSurfaceSource(
        using capabilities: MDKPrivateCaptureCapabilities
    ) -> Bool {
        capabilities.supportsIOSurfaceDisplayCapture
    }

    var resolvedEncoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy {
        resolvedEncoderInputStrategy(using: MDKPrivateCaptureCapabilityProbe.current())
    }

    func resolvedEncoderInputStrategy(
        using capabilities: MDKPrivateCaptureCapabilities
    ) -> MDKEncodedCaptureEncoderInputStrategy {
        guard encoderInputStrategy == .auto else {
            return encoderInputStrategy
        }

        switch resolvedSourceBackend(using: capabilities) {
        case .privateDirectIOSurface:
            switch codec {
            case .h264:
                return .yuv420v8
            case .hevc:
                let usesHDRTransfer = resolvedEncodedHDRConfiguration.map { $0.transferFunction != .ituR709 } ?? false
                return usesHDRTransfer ? .yuv420v10 : .yuv420v8
            case .proResProxy:
                return .bgra
            }
        case .skyLightDisplayStream:
            return .auto
        }
    }

    var resolvedSkyLightDisplayStreamYCbCrMatrix: MDKVideoYCbCrMatrix? {
        switch resolvedCapturePixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return resolvedEncodedHDRConfiguration?.yCbCrMatrix ?? .ituR709
        default:
            return nil
        }
    }

    var resolvedSkyLightProcessingMode: MDKCaptureBenchmarkProcessingMode? {
        switch (codec, preprocessStrategy) {
        case (.hevc, .none):
            return .videoToolboxEncode
        case (.hevc, .downscale2x):
            return .videoToolboxEncodeDownscale2x
        case (.h264, .none):
            return .videoToolboxEncodeH264
        case (.h264, .downscale2x):
            return .videoToolboxEncodeH264Downscale2x
        case (.proResProxy, _):
            return .videoToolboxEncodeProResProxyExperimental
        }
    }
}
