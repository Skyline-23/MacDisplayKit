import CoreMedia
import VideoToolbox

public enum MDKVideoPreprocessStrategy: String, CaseIterable, Codable, Sendable {
    case none
    case downscale2x = "downscale-2x"

    public var localizedName: String {
        rawValue
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
    case h264
    case hevc
    case av1

    var codecType: CMVideoCodecType {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .av1:
            return kCMVideoCodecType_AV1
        }
    }

    var localizedName: String {
        rawValue
    }

    var defaultProfileLevel: CFString? {
        switch self {
        case .h264:
            return kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        case .av1:
            return nil
        }
    }

    var lowLatencyRateControlSupported: Bool {
        switch self {
        case .h264:
            return true
        case .hevc, .av1:
            return false
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
            return min(max(pixelsPerSecond / 20, 12_000_000), 36_000_000)
        case .av1:
            return min(max(pixelsPerSecond / 24, 10_000_000), 32_000_000)
        }
    }

    func dataRateLimits(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> [NSNumber] {
        let averageBitRate = averageBitRate(width: width, height: height, frameRate: frameRate)
        let oneSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 1.20)
        let quarterSecondLimitBytes = Int((Double(averageBitRate) / 8.0) * 0.35)
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
        case .av1:
            return 0.34
        }
    }

    var referenceBufferCount: Int {
        switch self {
        case .h264:
            return 1
        case .hevc:
            return 2
        case .av1:
            return 2
        }
    }
}
