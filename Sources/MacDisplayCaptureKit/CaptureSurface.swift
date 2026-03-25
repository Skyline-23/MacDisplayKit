import Foundation
import CoreVideo
import IOSurface
import Metal

public enum MDKCaptureSurfacePlaneError: Error, LocalizedError, Equatable {
    case planeOutOfRange(requestedPlane: Int, planeCount: Int)
    case unsupportedPixelFormat(pixelFormat: UInt32, plane: Int)

    public var errorDescription: String? {
        switch self {
        case .planeOutOfRange(let requestedPlane, let planeCount):
            return "Plane \(requestedPlane) is outside the valid range for surface with \(planeCount) plane(s)."
        case .unsupportedPixelFormat(let pixelFormat, let plane):
            return "Pixel format \(pixelFormat) does not have a Metal mapping for plane \(plane)."
        }
    }
}

public struct MDKMetalPlaneDescriptor: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixelFormat: MTLPixelFormat
    public let plane: Int
}

public final class MDKCaptureSurface: @unchecked Sendable, Equatable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let pixelFormat: UInt32
    public let planeCount: Int

    private let ioSurface: IOSurfaceRef

    public convenience init(ioSurface: IOSurfaceRef) {
        self.init(
            ioSurface: ioSurface,
            id: IOSurfaceGetID(ioSurface),
            width: IOSurfaceGetWidth(ioSurface),
            height: IOSurfaceGetHeight(ioSurface),
            pixelFormat: IOSurfaceGetPixelFormat(ioSurface),
            planeCount: max(Int(IOSurfaceGetPlaneCount(ioSurface)), 0)
        )
    }

    init(
        ioSurface: IOSurfaceRef,
        id: UInt32,
        width: Int,
        height: Int,
        pixelFormat: UInt32,
        planeCount: Int
    ) {
        // Capture callbacks can hand us an IOSurface whose lifetime does not extend
        // beyond the callback scope, so retain it explicitly before handing it to
        // asynchronous processing stages.
        self.ioSurface = Unmanaged.passRetained(ioSurface).takeUnretainedValue()
        self.id = id
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.planeCount = planeCount
    }

    deinit {
        Unmanaged.passUnretained(ioSurface).release()
    }

    public static func == (lhs: MDKCaptureSurface, rhs: MDKCaptureSurface) -> Bool {
        lhs.id == rhs.id &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.pixelFormat == rhs.pixelFormat &&
        lhs.planeCount == rhs.planeCount
    }

    public func metalPlaneDescriptor(for plane: Int = 0) throws -> MDKMetalPlaneDescriptor {
        let normalizedPlaneCount = max(planeCount, 1)
        guard plane >= 0 && plane < normalizedPlaneCount else {
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(
                requestedPlane: plane,
                planeCount: normalizedPlaneCount
            )
        }

        return MDKMetalPlaneDescriptor(
            width: planeCount > 0 ? IOSurfaceGetWidthOfPlane(ioSurface, plane) : width,
            height: planeCount > 0 ? IOSurfaceGetHeightOfPlane(ioSurface, plane) : height,
            pixelFormat: try MDKMetalPixelFormat(for: pixelFormat, plane: plane),
            plane: plane
        )
    }

    public func makeMetalTexture(
        device: any MTLDevice,
        plane: Int = 0,
        usage: MTLTextureUsage = [.shaderRead]
    ) throws -> MTLTexture? {
        let descriptor = try metalPlaneDescriptor(for: plane)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.pixelFormat,
            width: descriptor.width,
            height: descriptor.height,
            mipmapped: false
        )
        textureDescriptor.usage = usage
        textureDescriptor.storageMode = .shared

        return device.makeTexture(
            descriptor: textureDescriptor,
            iosurface: ioSurface,
            plane: descriptor.plane
        )
    }

    var rawIOSurface: IOSurfaceRef {
        ioSurface
    }
}

func MDKMetalPixelFormat(for pixelFormat: UInt32, plane: Int) throws -> MTLPixelFormat {
    switch pixelFormat {
    case kCVPixelFormatType_32BGRA:
        guard plane == 0 else {
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(requestedPlane: plane, planeCount: 1)
        }
        return .bgra8Unorm
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        switch plane {
        case 0: return .r8Unorm
        case 1: return .rg8Unorm
        default:
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(requestedPlane: plane, planeCount: 2)
        }
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        switch plane {
        case 0: return .r16Unorm
        case 1: return .rg16Unorm
        default:
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(requestedPlane: plane, planeCount: 2)
        }
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        switch plane {
        case 0: return .r8Unorm
        case 1: return .rg8Unorm
        default:
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(requestedPlane: plane, planeCount: 2)
        }
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        switch plane {
        case 0: return .r16Unorm
        case 1: return .rg16Unorm
        default:
            throw MDKCaptureSurfacePlaneError.planeOutOfRange(requestedPlane: plane, planeCount: 2)
        }
    default:
        throw MDKCaptureSurfacePlaneError.unsupportedPixelFormat(pixelFormat: pixelFormat, plane: plane)
    }
}
