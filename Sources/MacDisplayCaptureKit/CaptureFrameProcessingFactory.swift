import Foundation

enum MDKCaptureFrameProcessingFactory {
    static func make(
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> any MDKCaptureFrameProcessing {
        switch processingMode {
        case .none:
            return MDKNoopCaptureFrameProcessor()
        case .metalBind:
            return try MDKMetalTextureBindingProcessor()
        case .metalCopy:
            return try MDKMetalTextureCopyProcessor()
        case .videoToolboxEncode:
            return MDKVideoToolboxEncodingProcessor()
        }
    }
}
