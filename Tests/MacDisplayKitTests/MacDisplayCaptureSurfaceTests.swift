import CoreVideo
import IOSurface
import Metal
import XCTest
@testable import MacDisplayCaptureKit

final class MacDisplayCaptureSurfaceTests: XCTestCase {
    func testBGRAIOSurfaceProducesMetalTexture() throws {
        let surface = try makeBGRAIOSurface(width: 64, height: 32)
        let captureSurface = MDKCaptureSurface(ioSurface: surface)

        XCTAssertEqual(captureSurface.id, IOSurfaceGetID(surface))
        XCTAssertEqual(captureSurface.width, 64)
        XCTAssertEqual(captureSurface.height, 32)
        XCTAssertEqual(captureSurface.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(captureSurface.planeCount, 0)

        let descriptor = try captureSurface.metalPlaneDescriptor()
        XCTAssertEqual(descriptor.width, 64)
        XCTAssertEqual(descriptor.height, 32)
        XCTAssertEqual(descriptor.pixelFormat, .bgra8Unorm)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is not available on this host.")
        }

        let texture = try captureSurface.makeMetalTexture(device: device)
        XCTAssertNotNil(texture)
        XCTAssertEqual(texture?.width, 64)
        XCTAssertEqual(texture?.height, 32)
        XCTAssertEqual(texture?.pixelFormat, .bgra8Unorm)
    }

    func testMetalPixelFormatMapsBiplanarFormatsWithoutBackingSurface() throws {
        XCTAssertEqual(
            try MDKMetalPixelFormat(
                for: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                plane: 0
            ),
            .r16Unorm
        )
        XCTAssertEqual(
            try MDKMetalPixelFormat(
                for: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                plane: 1
            ),
            .rg16Unorm
        )
        XCTAssertEqual(
            try MDKMetalPixelFormat(
                for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                plane: 0
            ),
            .r8Unorm
        )
        XCTAssertEqual(
            try MDKMetalPixelFormat(
                for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                plane: 1
            ),
            .rg8Unorm
        )
    }

    func testUnsupportedPixelFormatThrows() {
        XCTAssertThrowsError(try MDKMetalPixelFormat(for: 0x12345678, plane: 0)) { error in
            XCTAssertEqual(
                error as? MDKCaptureSurfacePlaneError,
                .unsupportedPixelFormat(pixelFormat: 0x12345678, plane: 0)
            )
        }
    }

    private func makeBGRAIOSurface(width: Int, height: Int) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: width * 4,
        ]

        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            struct TestError: Error {}
            throw TestError()
        }

        return surface
    }
}
