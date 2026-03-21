import Foundation

enum MDKCaptureFrameProcessingFactory {
    static func make(
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> any MDKCaptureFrameProcessing {
        if let codec = processingMode.videoEncoderCodec {
            return MDKVideoToolboxEncodingProcessor(
                codec: codec,
                preprocessStrategy: processingMode.videoPreprocessStrategy
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
             .videoToolboxEncodeAV1,
             .videoToolboxEncodeAV1Downscale2x,
             .videoToolboxEncodeProResProxyExperimental:
            preconditionFailure("VideoToolbox processing modes should be handled before the switch.")
        }
    }
}
