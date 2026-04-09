import CoreMedia
import VideoToolbox

public enum MDKVideoPreprocessStrategy: String, CaseIterable, Codable, Sendable {
    case none
    case downscale2x = "downscale-2x"

    public var localizedName: String {
        switch self {
        case .none:
            return "None"
        case .downscale2x:
            return "Downscale 2x"
        }
    }

    func outputDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        pixelFormat: UInt32
    ) -> SIMD2<Int> {
        guard self == .downscale2x else {
            return SIMD2(sourceWidth, sourceHeight)
        }

        let requiresEvenDimensions: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            requiresEvenDimensions = true
        default:
            requiresEvenDimensions = false
        }

        func scaledDimension(_ value: Int) -> Int {
            let divided = max(value / 2, 2)
            guard requiresEvenDimensions else {
                return divided
            }
            return divided.isMultiple(of: 2) ? divided : (divided - 1)
        }

        return SIMD2(
            max(scaledDimension(sourceWidth), 2),
            max(scaledDimension(sourceHeight), 2)
        )
    }
}

public enum MDKVideoEncoderCodec: String, CaseIterable, Codable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"
    case proResProxy = "prores-proxy"

    var codecType: CMVideoCodecType {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .proResProxy:
            return kCMVideoCodecType_AppleProRes422Proxy
        }
    }

    public var localizedName: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        case .proResProxy:
            return "ProRes Proxy"
        }
    }

    public var preferredCapturePixelFormat: UInt32 {
        switch self {
        case .hevc:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .h264:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .proResProxy:
            return kCVPixelFormatType_32BGRA
        }
    }

    func preferredInputPixelFormat(
        for sourcePixelFormat: UInt32,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        strategy: MDKEncodedCaptureEncoderInputStrategy = .auto
    ) -> UInt32 {
        let usesHDRTransfer = hdrConfiguration.map { $0.transferFunction != .ituR709 } ?? false

        switch strategy {
        case .auto:
            return autoPreferredInputPixelFormat(
                for: sourcePixelFormat,
                usesHDRTransfer: usesHDRTransfer
            )
        case .bgra:
            return kCVPixelFormatType_32BGRA
        case .yuv420v8:
            return preferred420InputPixelFormat(
                for: sourcePixelFormat,
                preferredBitDepth: 8
            )
        case .yuv420v10:
            return preferred420InputPixelFormat(
                for: sourcePixelFormat,
                preferredBitDepth: 10
            )
        }
    }

    private func autoPreferredInputPixelFormat(
        for sourcePixelFormat: UInt32,
        usesHDRTransfer: Bool
    ) -> UInt32 {
        switch self {
        case .hevc:
            if !usesHDRTransfer {
                switch sourcePixelFormat {
                case kCVPixelFormatType_32BGRA,
                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                     kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                     kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                    return sourcePixelFormat
                default:
                    return kCVPixelFormatType_32BGRA
                }
            }
            return preferred420InputPixelFormat(
                for: sourcePixelFormat,
                preferredBitDepth: 10
            )
        case .h264:
            return preferred420InputPixelFormat(
                for: sourcePixelFormat,
                preferredBitDepth: 8
            )
        case .proResProxy:
            return preferred422InputPixelFormat(for: sourcePixelFormat)
        }
    }

    private func preferred420InputPixelFormat(
        for sourcePixelFormat: UInt32,
        preferredBitDepth: Int
    ) -> UInt32 {
        switch self {
        case .hevc:
            switch sourcePixelFormat {
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                return sourcePixelFormat
            default:
                return preferredBitDepth >= 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        case .h264:
            switch sourcePixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                return sourcePixelFormat
            default:
                return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        case .proResProxy:
            return preferred422InputPixelFormat(for: sourcePixelFormat)
        }
    }

    private func preferred422InputPixelFormat(
        for sourcePixelFormat: UInt32
    ) -> UInt32 {
        switch sourcePixelFormat {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return sourcePixelFormat
        default:
            return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        }
    }

    func defaultProfileLevel(for pixelFormat: UInt32) -> CFString? {
        switch self {
        case .h264:
            return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case .hevc:
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                return kVTProfileLevel_HEVC_Main10_AutoLevel
            default:
                return kVTProfileLevel_HEVC_Main_AutoLevel
            }
        case .proResProxy:
            return nil
        }
    }

    var lowLatencyRateControlSupported: Bool {
        switch self {
        case .h264, .hevc:
            return true
        case .proResProxy:
            return false
        }
    }

    func requiresDetachedSubmissionSurface(
        sourcePixelFormat: UInt32,
        targetPixelFormat: UInt32,
        needsScaling: Bool,
        hasCursorOverlay: Bool
    ) -> Bool {
        if needsScaling || sourcePixelFormat != targetPixelFormat || hasCursorOverlay {
            return true
        }

        switch self {
        case .h264, .hevc:
            switch sourcePixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
                return false
            default:
                return true
            }
        case .proResProxy:
            return true
        }
    }

    func averageBitRate(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> Int {
        let pixelsPerSecond = max(width * height * frameRate, 1)
        switch self {
        case .h264:
            return min(max(pixelsPerSecond / 12, 20_000_000), 60_000_000)
        case .hevc:
            return min(max(pixelsPerSecond / 10, 32_000_000), 96_000_000)
        case .proResProxy:
            return min(max(pixelsPerSecond / 5, 40_000_000), 140_000_000)
        }
    }

    func lowLatencyAverageBitRate(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> Int {
        let pixelsPerSecond = max(width * height * frameRate, 1)
        switch self {
        case .h264:
            return min(max(pixelsPerSecond / 10, 32_000_000), 90_000_000)
        case .hevc:
            return min(max(pixelsPerSecond / 4, 120_000_000), 192_000_000)
        case .proResProxy:
            return averageBitRate(width: width, height: height, frameRate: frameRate)
        }
    }

    func dataRateLimits(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> [NSNumber] {
        let averageBitRate = averageBitRate(width: width, height: height, frameRate: frameRate)
        return dataRateLimits(forAverageBitRate: averageBitRate, lowLatency: false)
    }

    func lowLatencyDataRateLimits(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> [NSNumber] {
        let averageBitRate = lowLatencyAverageBitRate(width: width, height: height, frameRate: frameRate)
        return dataRateLimits(forAverageBitRate: averageBitRate, lowLatency: true)
    }

    func dataRateLimits(
        forAverageBitRate averageBitRate: Int,
        lowLatency: Bool
    ) -> [NSNumber] {
        let oneSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 1.75)
        let quarterSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 0.65)
        if !lowLatency {
            let oneSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 1.50)
            let quarterSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 0.50)
            return [
                NSNumber(value: quarterSecondLimitBytes),
                NSNumber(value: 0.25),
                NSNumber(value: oneSecondLimitBytes),
                NSNumber(value: 1.0)
            ]
        }
        return [
            NSNumber(value: quarterSecondLimitBytes),
            NSNumber(value: 0.25),
            NSNumber(value: oneSecondLimitBytes),
            NSNumber(value: 1.0)
        ]
    }

    var targetQuality: Float {
        switch self {
        case .h264:
            return 0.42
        case .hevc:
            return 0.36
        case .proResProxy:
            return 0.30
        }
    }

    var referenceBufferCount: Int {
        switch self {
        case .h264:
            return 1
        case .hevc:
            return 1
        case .proResProxy:
            return 0
        }
    }

    var supportsAverageBitRate: Bool {
        switch self {
        case .proResProxy:
            return false
        case .h264, .hevc:
            return true
        }
    }

    var supportsDataRateLimits: Bool {
        switch self {
        case .proResProxy:
            return false
        case .h264, .hevc:
            return true
        }
    }

    var supportsQualityProperty: Bool {
        switch self {
        case .h264, .hevc:
            return true
        case .proResProxy:
            return false
        }
    }

    var supportsReferenceBufferCount: Bool {
        switch self {
        case .proResProxy:
            return false
        case .h264, .hevc:
            return true
        }
    }
}
