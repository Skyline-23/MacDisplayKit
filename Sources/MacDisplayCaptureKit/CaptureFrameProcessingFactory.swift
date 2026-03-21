import Foundation

enum MDKCaptureFrameProcessingFactory {
    static func make(
        processingMode: MDKCaptureBenchmarkProcessingMode,
        targetFrameRate: Int = 120
    ) throws -> any MDKCaptureFrameProcessing {
        if let codec = processingMode.videoEncoderCodec {
            return MDKVideoToolboxEncodingProcessor(
                codec: codec,
                preprocessStrategy: processingMode.videoPreprocessStrategy,
                targetFrameRate: targetFrameRate
            )
        }

        switch processingMode {
        case .none:
            return MDKNoopCaptureFrameProcessor()
        case .metalBind:
            return try MDKMetalTextureBindingProcessor()
        case .metalCopy:
            return try MDKMetalTextureCopyProcessor()
        case .videoToolboxEncode,
             .videoToolboxEncodeDownscale2x,
             .videoToolboxEncodeH264,
             .videoToolboxEncodeH264Downscale2x,
             .videoToolboxEncodeProResProxyExperimental:
            preconditionFailure("VideoToolbox processing modes should be handled before the switch.")
        }
    }
}
