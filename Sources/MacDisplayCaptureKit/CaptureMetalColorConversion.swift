import CoreVideo
import Metal
import simd

enum MDKMetalColorConversionError: Error, LocalizedError, Equatable {
    case unsupportedSourcePixelFormat(UInt32)
    case unsupportedDestinationPixelFormat(UInt32)
    case libraryCreationFailed(String)
    case functionMissing(String)
    case pipelineCreationFailed(String)
    case invalidTextureTopology
    case commandEncoderUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedSourcePixelFormat(let pixelFormat):
            return String(format: "Unsupported source pixel format for Metal color conversion: 0x%08X", pixelFormat)
        case .unsupportedDestinationPixelFormat(let pixelFormat):
            return String(format: "Unsupported destination pixel format for Metal color conversion: 0x%08X", pixelFormat)
        case .libraryCreationFailed(let reason):
            return "Unable to compile the Metal color conversion library: \(reason)"
        case .functionMissing(let functionName):
            return "The Metal color conversion function \(functionName) is unavailable."
        case .pipelineCreationFailed(let reason):
            return "Unable to build the Metal color conversion pipeline: \(reason)"
        case .invalidTextureTopology:
            return "The Metal color conversion path expects one BGRA source texture and two bi-planar destination textures."
        case .commandEncoderUnavailable:
            return "Unable to create a Metal compute command encoder for color conversion."
        }
    }
}

private struct MDKMetalYCbCrConversionParameters {
    var sourceSize: SIMD2<UInt32>
    var destinationLumaSize: SIMD2<UInt32>
    var chromaSubsampling: SIMD2<UInt32>
    var cursorOverlayEnabled: UInt32
    var cursorOverlayVerticallyFlipped: UInt32
    var rgbTransformRow0: SIMD4<Float>
    var rgbTransformRow1: SIMD4<Float>
    var rgbTransformRow2: SIMD4<Float>
    var cursorRect: SIMD4<Float>
    var yCoefficients: SIMD4<Float>
    var cbCoefficients: SIMD4<Float>
    var crCoefficients: SIMD4<Float>
    var lumaScale: Float
    var lumaOffset: Float
    var chromaScale: Float
    var chromaOffset: Float
}

private struct MDKMetalCursorOverlayParameters {
    var destinationSize: SIMD2<UInt32>
    var cursorOverlayVerticallyFlipped: UInt32
    var reserved: UInt32
    var cursorRect: SIMD4<Float>
}

private struct MDKMetalYCbCrTargetDescription {
    let pixelFormat: UInt32
    let chromaSubsampling: SIMD2<UInt32>
    let sourceColorPrimaries: MDKVideoColorPrimaries
    let signalColorPrimaries: MDKVideoColorPrimaries
    let rgbTransform: simd_float3x3
    let yCoefficients: SIMD4<Float>
    let cbCoefficients: SIMD4<Float>
    let crCoefficients: SIMD4<Float>
    let lumaScale: Float
    let lumaOffset: Float
    let chromaScale: Float
    let chromaOffset: Float
}

private struct MDKMetalYCbCrCoefficientSet {
    let yCoefficients: SIMD4<Float>
    let cbCoefficients: SIMD4<Float>
    let crCoefficients: SIMD4<Float>
}

final class MDKMetalBGRAToYCbCrConverter {
    private let device: any MTLDevice
    private let lumaPipeline: any MTLComputePipelineState
    private let chromaPipeline: any MTLComputePipelineState
    private let combined420Pipeline: any MTLComputePipelineState
    private let bgraCursorOverlayPipeline: any MTLComputePipelineState
    private let transparentCursorTexture: any MTLTexture

    init(device: any MTLDevice) throws {
        self.device = device

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MDKMetalColorConversionError.libraryCreationFailed(String(describing: error))
        }

        guard let lumaFunction = library.makeFunction(name: "bgraToYCbCrLuma"),
              let chromaFunction = library.makeFunction(name: "bgraToYCbCrChroma"),
              let combined420Function = library.makeFunction(name: "bgraToYCbCr420Combined"),
              let bgraCursorOverlayFunction = library.makeFunction(name: "overlayCursorOnBGRA") else {
            throw MDKMetalColorConversionError.functionMissing(
                "bgraToYCbCrLuma/bgraToYCbCrChroma/bgraToYCbCr420Combined/overlayCursorOnBGRA"
            )
        }

        do {
            lumaPipeline = try device.makeComputePipelineState(function: lumaFunction)
            chromaPipeline = try device.makeComputePipelineState(function: chromaFunction)
            combined420Pipeline = try device.makeComputePipelineState(function: combined420Function)
            bgraCursorOverlayPipeline = try device.makeComputePipelineState(function: bgraCursorOverlayFunction)
        } catch {
            throw MDKMetalColorConversionError.pipelineCreationFailed(String(describing: error))
        }

        let transparentTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        transparentTextureDescriptor.usage = [.shaderRead]
        transparentTextureDescriptor.storageMode = .shared
        guard let transparentCursorTexture = device.makeTexture(descriptor: transparentTextureDescriptor) else {
            throw MDKMetalColorConversionError.pipelineCreationFailed("Unable to create a transparent cursor texture.")
        }
        var transparentPixel: UInt32 = 0
        transparentCursorTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &transparentPixel,
            bytesPerRow: MemoryLayout<UInt32>.size
        )
        self.transparentCursorTexture = transparentCursorTexture
    }

    func encode(
        commandBuffer: any MTLCommandBuffer,
        sourceTextures: [MTLTexture],
        destinationTextures: [MTLTexture],
        destinationPixelFormat: UInt32,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        cursorTexture: MTLTexture? = nil,
        cursorOverlaySample: MDKCursorOverlaySample? = nil
    ) throws {
        guard sourceTextures.count == 1,
              destinationTextures.count == 2 else {
            throw MDKMetalColorConversionError.invalidTextureTopology
        }
        guard sourceTextures[0].pixelFormat == .bgra8Unorm else {
            throw MDKMetalColorConversionError.unsupportedSourcePixelFormat(kCVPixelFormatType_32BGRA)
        }

        let target = try Self.targetDescription(
            for: destinationPixelFormat,
            hdrConfiguration: hdrConfiguration
        )
        let cursorRect = cursorOverlaySample.map {
            SIMD4(
                Float($0.rect.minX),
                Float($0.rect.minY),
                Float($0.rect.width),
                Float($0.rect.height)
            )
        } ?? SIMD4<Float>(repeating: 0)
        var parameters = MDKMetalYCbCrConversionParameters(
            sourceSize: SIMD2(UInt32(sourceTextures[0].width), UInt32(sourceTextures[0].height)),
            destinationLumaSize: SIMD2(UInt32(destinationTextures[0].width), UInt32(destinationTextures[0].height)),
            chromaSubsampling: target.chromaSubsampling,
            cursorOverlayEnabled: cursorOverlaySample == nil ? 0 : 1,
            cursorOverlayVerticallyFlipped: cursorOverlaySample?.isVerticallyFlipped == true ? 1 : 0,
            rgbTransformRow0: SIMD4(target.rgbTransform[0][0], target.rgbTransform[1][0], target.rgbTransform[2][0], 0),
            rgbTransformRow1: SIMD4(target.rgbTransform[0][1], target.rgbTransform[1][1], target.rgbTransform[2][1], 0),
            rgbTransformRow2: SIMD4(target.rgbTransform[0][2], target.rgbTransform[1][2], target.rgbTransform[2][2], 0),
            cursorRect: cursorRect,
            yCoefficients: target.yCoefficients,
            cbCoefficients: target.cbCoefficients,
            crCoefficients: target.crCoefficients,
            lumaScale: target.lumaScale,
            lumaOffset: target.lumaOffset,
            chromaScale: target.chromaScale,
            chromaOffset: target.chromaOffset
        )

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MDKMetalColorConversionError.commandEncoderUnavailable
        }

        computeEncoder.setBytes(
            &parameters,
            length: MemoryLayout<MDKMetalYCbCrConversionParameters>.stride,
            index: 0
        )

        computeEncoder.setTexture(sourceTextures[0], index: 0)
        computeEncoder.setTexture(destinationTextures[0], index: 1)
        computeEncoder.setTexture(cursorTexture ?? transparentCursorTexture, index: 2)
        if target.chromaSubsampling == SIMD2<UInt32>(2, 2),
           destinationTextures[1].width * 2 == destinationTextures[0].width,
           destinationTextures[1].height * 2 == destinationTextures[0].height {
            computeEncoder.setTexture(destinationTextures[1], index: 2)
            computeEncoder.setTexture(cursorTexture ?? transparentCursorTexture, index: 3)
            computeEncoder.setComputePipelineState(combined420Pipeline)
            dispatch(
                encoder: computeEncoder,
                pipeline: combined420Pipeline,
                width: destinationTextures[1].width,
                height: destinationTextures[1].height
            )
            computeEncoder.endEncoding()
            return
        }

        computeEncoder.setComputePipelineState(lumaPipeline)
        dispatch(
            encoder: computeEncoder,
            pipeline: lumaPipeline,
            width: destinationTextures[0].width,
            height: destinationTextures[0].height
        )

        computeEncoder.setTexture(sourceTextures[0], index: 0)
        computeEncoder.setTexture(destinationTextures[1], index: 1)
        computeEncoder.setTexture(cursorTexture ?? transparentCursorTexture, index: 2)
        computeEncoder.setComputePipelineState(chromaPipeline)
        dispatch(
            encoder: computeEncoder,
            pipeline: chromaPipeline,
            width: destinationTextures[1].width,
            height: destinationTextures[1].height
        )

        computeEncoder.endEncoding()
    }

    func overlayCursorOnBGRA(
        commandBuffer: any MTLCommandBuffer,
        destinationTexture: MTLTexture,
        cursorTexture: MTLTexture,
        cursorRect: CGRect,
        cursorVerticallyFlipped: Bool
    ) throws {
        var parameters = MDKMetalCursorOverlayParameters(
            destinationSize: SIMD2(UInt32(destinationTexture.width), UInt32(destinationTexture.height)),
            cursorOverlayVerticallyFlipped: cursorVerticallyFlipped ? 1 : 0,
            reserved: 0,
            cursorRect: SIMD4(
                Float(cursorRect.minX),
                Float(cursorRect.minY),
                Float(cursorRect.width),
                Float(cursorRect.height)
            )
        )
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MDKMetalColorConversionError.commandEncoderUnavailable
        }
        computeEncoder.setBytes(
            &parameters,
            length: MemoryLayout<MDKMetalCursorOverlayParameters>.stride,
            index: 0
        )
        computeEncoder.setTexture(cursorTexture, index: 0)
        computeEncoder.setTexture(destinationTexture, index: 1)
        computeEncoder.setComputePipelineState(bgraCursorOverlayPipeline)
        dispatch(
            encoder: computeEncoder,
            pipeline: bgraCursorOverlayPipeline,
            width: destinationTexture.width,
            height: destinationTexture.height
        )
        computeEncoder.endEncoding()
    }

    private func dispatch(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = min(max(pipeline.threadExecutionWidth, 1), width)
        let maxThreads = max(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        let threadHeight = min(maxThreads, max(height, 1))
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: max(width, 1), height: max(height, 1), depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    private static func defaultTargetDescription(for pixelFormat: UInt32) throws -> MDKMetalYCbCrTargetDescription {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 2),
                sourceColorPrimaries: .ituR709,
                signalColorPrimaries: .ituR709,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2126, 0.7152, 0.0722, 0),
                cbCoefficients: SIMD4(-0.114572, -0.385428, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.454153, -0.045847, 0.5),
                lumaScale: 219.0 / 255.0,
                lumaOffset: 16.0 / 255.0,
                chromaScale: 224.0 / 255.0,
                chromaOffset: 16.0 / 255.0
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 2),
                sourceColorPrimaries: .ituR709,
                signalColorPrimaries: .ituR709,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2126, 0.7152, 0.0722, 0),
                cbCoefficients: SIMD4(-0.114572, -0.385428, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.454153, -0.045847, 0.5),
                lumaScale: 1,
                lumaOffset: 0,
                chromaScale: 1,
                chromaOffset: 0
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 2),
                sourceColorPrimaries: .ituR2020,
                signalColorPrimaries: .ituR2020,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2627, 0.6780, 0.0593, 0),
                cbCoefficients: SIMD4(-0.13963, -0.36037, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.459786, -0.040214, 0.5),
                lumaScale: 219.0 / 1023.0,
                lumaOffset: 64.0 / 1023.0,
                chromaScale: 224.0 / 1023.0,
                chromaOffset: 64.0 / 1023.0
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 2),
                sourceColorPrimaries: .ituR2020,
                signalColorPrimaries: .ituR2020,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2627, 0.6780, 0.0593, 0),
                cbCoefficients: SIMD4(-0.13963, -0.36037, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.459786, -0.040214, 0.5),
                lumaScale: 1,
                lumaOffset: 0,
                chromaScale: 1,
                chromaOffset: 0
            )
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 1),
                sourceColorPrimaries: .ituR709,
                signalColorPrimaries: .ituR709,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2126, 0.7152, 0.0722, 0),
                cbCoefficients: SIMD4(-0.114572, -0.385428, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.454153, -0.045847, 0.5),
                lumaScale: 219.0 / 255.0,
                lumaOffset: 16.0 / 255.0,
                chromaScale: 224.0 / 255.0,
                chromaOffset: 16.0 / 255.0
            )
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 1),
                sourceColorPrimaries: .ituR709,
                signalColorPrimaries: .ituR709,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2126, 0.7152, 0.0722, 0),
                cbCoefficients: SIMD4(-0.114572, -0.385428, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.454153, -0.045847, 0.5),
                lumaScale: 1,
                lumaOffset: 0,
                chromaScale: 1,
                chromaOffset: 0
            )
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 1),
                sourceColorPrimaries: .ituR2020,
                signalColorPrimaries: .ituR2020,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2627, 0.6780, 0.0593, 0),
                cbCoefficients: SIMD4(-0.13963, -0.36037, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.459786, -0.040214, 0.5),
                lumaScale: 219.0 / 1023.0,
                lumaOffset: 64.0 / 1023.0,
                chromaScale: 224.0 / 1023.0,
                chromaOffset: 64.0 / 1023.0
            )
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return MDKMetalYCbCrTargetDescription(
                pixelFormat: pixelFormat,
                chromaSubsampling: SIMD2(2, 1),
                sourceColorPrimaries: .ituR2020,
                signalColorPrimaries: .ituR2020,
                rgbTransform: matrix_identity_float3x3,
                yCoefficients: SIMD4(0.2627, 0.6780, 0.0593, 0),
                cbCoefficients: SIMD4(-0.13963, -0.36037, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.459786, -0.040214, 0.5),
                lumaScale: 1,
                lumaOffset: 0,
                chromaScale: 1,
                chromaOffset: 0
            )
        default:
            throw MDKMetalColorConversionError.unsupportedDestinationPixelFormat(pixelFormat)
        }
    }

    private static func targetDescription(
        for pixelFormat: UInt32,
        hdrConfiguration: MDKVideoHDRConfiguration?
    ) throws -> MDKMetalYCbCrTargetDescription {
        let target = try defaultTargetDescription(for: pixelFormat)
        guard let hdrConfiguration else {
            return target
        }

        let coefficients = coefficients(for: hdrConfiguration.yCbCrMatrix)
        let sourceColorPrimaries = hdrConfiguration.sourceColorPrimaries ?? hdrConfiguration.colorPrimaries
        let signalColorPrimaries = hdrConfiguration.colorPrimaries
        return MDKMetalYCbCrTargetDescription(
            pixelFormat: target.pixelFormat,
            chromaSubsampling: target.chromaSubsampling,
            sourceColorPrimaries: sourceColorPrimaries,
            signalColorPrimaries: signalColorPrimaries,
            rgbTransform: rgbTransform(
                from: sourceColorPrimaries,
                to: signalColorPrimaries
            ),
            yCoefficients: coefficients.yCoefficients,
            cbCoefficients: coefficients.cbCoefficients,
            crCoefficients: coefficients.crCoefficients,
            lumaScale: target.lumaScale,
            lumaOffset: target.lumaOffset,
            chromaScale: target.chromaScale,
            chromaOffset: target.chromaOffset
        )
    }

    private static func coefficients(for matrix: MDKVideoYCbCrMatrix) -> MDKMetalYCbCrCoefficientSet {
        switch matrix {
        case .ituR709:
            return MDKMetalYCbCrCoefficientSet(
                yCoefficients: SIMD4(0.2126, 0.7152, 0.0722, 0),
                cbCoefficients: SIMD4(-0.114572, -0.385428, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.454153, -0.045847, 0.5)
            )
        case .ituR2020:
            return MDKMetalYCbCrCoefficientSet(
                yCoefficients: SIMD4(0.2627, 0.6780, 0.0593, 0),
                cbCoefficients: SIMD4(-0.13963, -0.36037, 0.5, 0.5),
                crCoefficients: SIMD4(0.5, -0.459786, -0.040214, 0.5)
            )
        }
    }

    private static func rgbTransform(
        from source: MDKVideoColorPrimaries,
        to destination: MDKVideoColorPrimaries
    ) -> simd_float3x3 {
        guard source != destination else {
            return matrix_identity_float3x3
        }
        return simd_inverse(rgbToXYZMatrix(for: destination)) * rgbToXYZMatrix(for: source)
    }

    private static func rgbToXYZMatrix(for primaries: MDKVideoColorPrimaries) -> simd_float3x3 {
        switch primaries {
        case .ituR709:
            return simd_float3x3(
                SIMD3(0.4123908, 0.2126390, 0.0193308),
                SIMD3(0.3575843, 0.7151687, 0.1191948),
                SIMD3(0.1804808, 0.0721923, 0.9505322)
            )
        case .ituR2020:
            return simd_float3x3(
                SIMD3(0.6369580, 0.2627002, 0.0000000),
                SIMD3(0.1446169, 0.6779981, 0.0280727),
                SIMD3(0.1688810, 0.0593017, 1.0609851)
            )
        case .p3D65:
            return simd_float3x3(
                SIMD3(0.4865709, 0.2289746, 0.0000000),
                SIMD3(0.2656677, 0.6917385, 0.0451134),
                SIMD3(0.1982173, 0.0792869, 1.0439444)
            )
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ConversionParameters {
        uint2 sourceSize;
        uint2 destinationLumaSize;
        uint2 chromaSubsampling;
        uint cursorOverlayEnabled;
        uint cursorOverlayVerticallyFlipped;
        float4 rgbTransformRow0;
        float4 rgbTransformRow1;
        float4 rgbTransformRow2;
        float4 cursorRect;
        float4 yCoefficients;
        float4 cbCoefficients;
        float4 crCoefficients;
        float lumaScale;
        float lumaOffset;
        float chromaScale;
        float chromaOffset;
    };

    struct CursorOverlayParameters {
        uint2 destinationSize;
        uint cursorOverlayVerticallyFlipped;
        uint reserved;
        float4 cursorRect;
    };

    inline float3 sampleRGB(
        texture2d<float, access::sample> sourceTexture,
        sampler linearSampler,
        float2 normalizedCoordinates
    ) {
        return sourceTexture.sample(linearSampler, normalizedCoordinates).rgb;
    }

    inline float3 transformRGB(
        float3 rgb,
        constant ConversionParameters &parameters
    ) {
        return float3(
            dot(float4(rgb, 1.0), parameters.rgbTransformRow0),
            dot(float4(rgb, 1.0), parameters.rgbTransformRow1),
            dot(float4(rgb, 1.0), parameters.rgbTransformRow2)
        );
    }

    inline float4 sampleCursor(
        texture2d<float, access::sample> cursorTexture,
        sampler linearSampler,
        float2 sourcePixel,
        constant ConversionParameters &parameters
    ) {
        if (parameters.cursorOverlayEnabled == 0 ||
            parameters.cursorRect.z <= 0.0 ||
            parameters.cursorRect.w <= 0.0) {
            return float4(0.0);
        }

        float2 cursorLocal = sourcePixel - parameters.cursorRect.xy;
        if (cursorLocal.x < 0.0 ||
            cursorLocal.y < 0.0 ||
            cursorLocal.x >= parameters.cursorRect.z ||
            cursorLocal.y >= parameters.cursorRect.w) {
            return float4(0.0);
        }

        float2 cursorUV = cursorLocal / parameters.cursorRect.zw;
        if (parameters.cursorOverlayVerticallyFlipped != 0) {
            cursorUV.y = 1.0 - cursorUV.y;
        }
        return cursorTexture.sample(linearSampler, cursorUV);
    }

    inline float3 applyCursorOverlay(
        float3 baseRGB,
        texture2d<float, access::sample> cursorTexture,
        sampler linearSampler,
        float2 sourcePixel,
        constant ConversionParameters &parameters
    ) {
        float4 cursor = sampleCursor(cursorTexture, linearSampler, sourcePixel, parameters);
        return mix(baseRGB, cursor.rgb, cursor.a);
    }

    kernel void bgraToYCbCrLuma(
        texture2d<float, access::sample> sourceTexture [[texture(0)]],
        texture2d<float, access::write> destinationTexture [[texture(1)]],
        texture2d<float, access::sample> cursorTexture [[texture(2)]],
        constant ConversionParameters &parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
            return;
        }

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 destinationSize = float2(parameters.destinationLumaSize);
        float2 normalizedCoordinates = (float2(gid) + float2(0.5)) / destinationSize;
        float2 sourcePixel = normalizedCoordinates * float2(parameters.sourceSize);
        float3 rgb = applyCursorOverlay(
            sampleRGB(sourceTexture, linearSampler, normalizedCoordinates),
            cursorTexture,
            linearSampler,
            sourcePixel,
            parameters
        );
        rgb = transformRGB(rgb, parameters);
        float y = dot(float4(rgb, 1.0), parameters.yCoefficients);
        float limitedY = clamp((y * parameters.lumaScale) + parameters.lumaOffset, 0.0, 1.0);
        destinationTexture.write(limitedY, gid);
    }

    kernel void bgraToYCbCrChroma(
        texture2d<float, access::sample> sourceTexture [[texture(0)]],
        texture2d<float, access::write> destinationTexture [[texture(1)]],
        texture2d<float, access::sample> cursorTexture [[texture(2)]],
        constant ConversionParameters &parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
            return;
        }

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 lumaSize = float2(parameters.destinationLumaSize);
        float2 chromaSubsampling = float2(parameters.chromaSubsampling);
        float2 basePixel = float2(gid) * chromaSubsampling;

        float3 rgb = float3(0.0);
        uint sampleCount = 0;
        for (uint offsetY = 0; offsetY < parameters.chromaSubsampling.y; ++offsetY) {
            for (uint offsetX = 0; offsetX < parameters.chromaSubsampling.x; ++offsetX) {
                float2 sampleCoordinate = (
                    basePixel + float2(float(offsetX) + 0.5, float(offsetY) + 0.5)
                ) / lumaSize;
                float2 sourcePixel = sampleCoordinate * float2(parameters.sourceSize);
                float3 sample = applyCursorOverlay(
                    sampleRGB(sourceTexture, linearSampler, sampleCoordinate),
                    cursorTexture,
                    linearSampler,
                    sourcePixel,
                    parameters
                );
                rgb += transformRGB(sample, parameters);
                sampleCount += 1;
            }
        }
        rgb *= 1.0 / max(float(sampleCount), 1.0);

        float cb = dot(float4(rgb, 1.0), parameters.cbCoefficients);
        float cr = dot(float4(rgb, 1.0), parameters.crCoefficients);
        float2 limitedUV = clamp(
            (float2(cb, cr) * parameters.chromaScale) + parameters.chromaOffset,
            float2(0.0),
            float2(1.0)
        );
        destinationTexture.write(float4(limitedUV.x, limitedUV.y, 0.0, 1.0), gid);
    }

    kernel void bgraToYCbCr420Combined(
        texture2d<float, access::sample> sourceTexture [[texture(0)]],
        texture2d<float, access::write> destinationLumaTexture [[texture(1)]],
        texture2d<float, access::write> destinationChromaTexture [[texture(2)]],
        texture2d<float, access::sample> cursorTexture [[texture(3)]],
        constant ConversionParameters &parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destinationChromaTexture.get_width() || gid.y >= destinationChromaTexture.get_height()) {
            return;
        }

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 lumaSize = float2(parameters.destinationLumaSize);
        uint2 basePixel = gid * uint2(2, 2);

        float3 chromaRGB = float3(0.0);
        uint sampleCount = 0;
        for (uint offsetY = 0; offsetY < 2; ++offsetY) {
            for (uint offsetX = 0; offsetX < 2; ++offsetX) {
                uint2 lumaGID = basePixel + uint2(offsetX, offsetY);
                if (lumaGID.x >= destinationLumaTexture.get_width() ||
                    lumaGID.y >= destinationLumaTexture.get_height()) {
                    continue;
                }

                float2 sampleCoordinate = (float2(lumaGID) + float2(0.5)) / lumaSize;
                float2 sourcePixel = sampleCoordinate * float2(parameters.sourceSize);
                float3 rgb = applyCursorOverlay(
                    sampleRGB(sourceTexture, linearSampler, sampleCoordinate),
                    cursorTexture,
                    linearSampler,
                    sourcePixel,
                    parameters
                );
                rgb = transformRGB(rgb, parameters);

                float y = dot(float4(rgb, 1.0), parameters.yCoefficients);
                float limitedY = clamp((y * parameters.lumaScale) + parameters.lumaOffset, 0.0, 1.0);
                destinationLumaTexture.write(limitedY, lumaGID);

                chromaRGB += rgb;
                sampleCount += 1;
            }
        }
        chromaRGB *= 1.0 / max(float(sampleCount), 1.0);

        float cb = dot(float4(chromaRGB, 1.0), parameters.cbCoefficients);
        float cr = dot(float4(chromaRGB, 1.0), parameters.crCoefficients);
        float2 limitedUV = clamp(
            (float2(cb, cr) * parameters.chromaScale) + parameters.chromaOffset,
            float2(0.0),
            float2(1.0)
        );
        destinationChromaTexture.write(float4(limitedUV.x, limitedUV.y, 0.0, 1.0), gid);
    }

    kernel void overlayCursorOnBGRA(
        texture2d<float, access::sample> cursorTexture [[texture(0)]],
        texture2d<float, access::read_write> destinationTexture [[texture(1)]],
        constant CursorOverlayParameters &parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
            return;
        }
        if (parameters.cursorRect.z <= 0.0 || parameters.cursorRect.w <= 0.0) {
            return;
        }

        float2 destinationPixel = float2(gid) + float2(0.5);
        float2 cursorLocal = destinationPixel - parameters.cursorRect.xy;
        if (cursorLocal.x < 0.0 ||
            cursorLocal.y < 0.0 ||
            cursorLocal.x >= parameters.cursorRect.z ||
            cursorLocal.y >= parameters.cursorRect.w) {
            return;
        }

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 cursorUV = cursorLocal / parameters.cursorRect.zw;
        if (parameters.cursorOverlayVerticallyFlipped != 0) {
            cursorUV.y = 1.0 - cursorUV.y;
        }
        float4 cursor = cursorTexture.sample(linearSampler, cursorUV);
        if (cursor.a <= 0.0) {
            return;
        }

        float4 base = destinationTexture.read(gid);
        float4 composed = float4(mix(base.rgb, cursor.rgb, cursor.a), max(base.a, cursor.a));
        destinationTexture.write(composed, gid);
    }
    """
}
