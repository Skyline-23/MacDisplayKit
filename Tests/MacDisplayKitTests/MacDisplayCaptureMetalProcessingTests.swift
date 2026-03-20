import CoreVideo
import IOSurface
import Metal
import XCTest
@testable import MacDisplayCaptureKit

final class MacDisplayCaptureMetalProcessingTests: XCTestCase {
    func testMetalTextureBindingProcessorBindsBGRAFrame() throws {
        let device = try requireMetalDevice()
        let surface = try makeBGRAIOSurface(width: 1920, height: 1080)
        let frame = MDKCaptureFrame(
            sequenceNumber: 1,
            displayTime: 1,
            surfaceID: IOSurfaceGetID(surface),
            width: 1920,
            height: 1080,
            pixelFormat: kCVPixelFormatType_32BGRA,
            surface: MDKCaptureSurface(ioSurface: surface)
        )

        let processor = try MDKMetalTextureBindingProcessor(device: device)
        let boundFrame = try processor.bind(frame: frame)

        XCTAssertEqual(boundFrame.surfaceID, frame.surfaceID)
        XCTAssertEqual(boundFrame.planeDescriptors.count, 1)
        XCTAssertEqual(boundFrame.planeDescriptors[0].width, 1920)
        XCTAssertEqual(boundFrame.planeDescriptors[0].height, 1080)
        XCTAssertEqual(boundFrame.planeDescriptors[0].pixelFormat, .bgra8Unorm)
    }

    func testMetalTextureBindingProcessorRejectsFramesWithoutSurface() throws {
        let device = try requireMetalDevice()
        let processor = try MDKMetalTextureBindingProcessor(device: device)
        let frame = MDKCaptureFrame(
            sequenceNumber: 1,
            displayTime: 1,
            surfaceID: 0,
            width: 3840,
            height: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )

        XCTAssertThrowsError(try processor.bind(frame: frame)) { error in
            XCTAssertEqual(error as? MDKCaptureFrameProcessingError, .surfaceUnavailable)
        }
    }

    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is not available on this host.")
        }
        return device
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
            XCTFail("Expected IOSurfaceCreate to return a valid surface.")
            throw NSError(domain: "MacDisplayKitTests", code: 1)
        }

        return surface
    }
}
