import CoreMedia
import VideoToolbox

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
            return kVTProfileLevel_H264_High_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        case .av1:
            return nil
        }
    }
}
