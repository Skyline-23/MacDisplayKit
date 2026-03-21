import Foundation

enum MDKCaptureFrameProcessingFactory {
    static func make(
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> any MDKCaptureFrameProcessing {
        if let codec = processingMode.videoEncoderCodec {
            return MDKVideoToolboxEncodingProcessor(codec: codec)
        }

        switch processingMode {
        case .none:
            return MDKNoopCaptureFrameProcessor()
        case .metalBind:
            return try MDKMetalTextureBindingProcessor()
        case .metalCopy:
            return try MDKMetalTextureCopyProcessor()
        case .videoToolboxEncode, .videoToolboxEncodeH264, .videoToolboxEncodeAV1:
            preconditionFailure("VideoToolbox processing modes should be handled before the switch.")
        }
    }
}
