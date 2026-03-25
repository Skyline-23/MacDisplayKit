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
    var yCoefficients: SIMD4<Float>
    var cbCoefficients: SIMD4<Float>
    var crCoefficients: SIMD4<Float>
    var lumaScale: Float
    var lumaOffset: Float
    var chromaScale: Float
    var chromaOffset: Float
}

private struct MDKMetalYCbCrTargetDescription {
    let pixelFormat: UInt32
    let chromaSubsampling: SIMD2<UInt32>
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

    init(device: any MTLDevice) throws {
        self.device = device

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MDKMetalColorConversionError.libraryCreationFailed(String(describing: error))
        }

        guard let lumaFunction = library.makeFunction(name: "bgraToYCbCrLuma"),
              let chromaFunction = library.makeFunction(name: "bgraToYCbCrChroma") else {
            throw MDKMetalColorConversionError.functionMissing("bgraToYCbCrLuma/bgraToYCbCrChroma")
        }

        do {
            lumaPipeline = try device.makeComputePipelineState(function: lumaFunction)
            chromaPipeline = try device.makeComputePipelineState(function: chromaFunction)
        } catch {
            throw MDKMetalColorConversionError.pipelineCreationFailed(String(describing: error))
        }
    }

    func encode(
        commandBuffer: any MTLCommandBuffer,
        sourceTextures: [MTLTexture],
        destinationTextures: [MTLTexture],
        destinationPixelFormat: UInt32,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil
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
        var parameters = MDKMetalYCbCrConversionParameters(
            sourceSize: SIMD2(UInt32(sourceTextures[0].width), UInt32(sourceTextures[0].height)),
            destinationLumaSize: SIMD2(UInt32(destinationTextures[0].width), UInt32(destinationTextures[0].height)),
            chromaSubsampling: target.chromaSubsampling,
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
        computeEncoder.setComputePipelineState(lumaPipeline)
        dispatch(
            encoder: computeEncoder,
            pipeline: lumaPipeline,
            width: destinationTextures[0].width,
            height: destinationTextures[0].height
        )

        computeEncoder.setTexture(sourceTextures[0], index: 0)
        computeEncoder.setTexture(destinationTextures[1], index: 1)
        computeEncoder.setComputePipelineState(chromaPipeline)
        dispatch(
            encoder: computeEncoder,
            pipeline: chromaPipeline,
            width: destinationTextures[1].width,
            height: destinationTextures[1].height
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
        return MDKMetalYCbCrTargetDescription(
            pixelFormat: target.pixelFormat,
            chromaSubsampling: target.chromaSubsampling,
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

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ConversionParameters {
        uint2 sourceSize;
        uint2 destinationLumaSize;
        uint2 chromaSubsampling;
        float4 yCoefficients;
        float4 cbCoefficients;
        float4 crCoefficients;
        float lumaScale;
        float lumaOffset;
        float chromaScale;
        float chromaOffset;
    };

    inline float3 sampleRGB(
        texture2d<float, access::sample> sourceTexture,
        sampler linearSampler,
        float2 normalizedCoordinates
    ) {
        return sourceTexture.sample(linearSampler, normalizedCoordinates).rgb;
    }

    kernel void bgraToYCbCrLuma(
        texture2d<float, access::sample> sourceTexture [[texture(0)]],
        texture2d<float, access::write> destinationTexture [[texture(1)]],
        constant ConversionParameters &parameters [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
            return;
        }

        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 destinationSize = float2(parameters.destinationLumaSize);
        float2 normalizedCoordinates = (float2(gid) + float2(0.5)) / destinationSize;
        float3 rgb = sampleRGB(sourceTexture, linearSampler, normalizedCoordinates);
        float y = dot(float4(rgb, 1.0), parameters.yCoefficients);
        float limitedY = clamp((y * parameters.lumaScale) + parameters.lumaOffset, 0.0, 1.0);
        destinationTexture.write(limitedY, gid);
    }

    kernel void bgraToYCbCrChroma(
        texture2d<float, access::sample> sourceTexture [[texture(0)]],
        texture2d<float, access::write> destinationTexture [[texture(1)]],
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
                rgb += sampleRGB(sourceTexture, linearSampler, sampleCoordinate);
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
    """
}
