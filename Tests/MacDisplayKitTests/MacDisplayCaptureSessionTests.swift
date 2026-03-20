import XCTest
import CoreMedia
import CoreVideo
@testable import MacDisplayKit
@testable import MacDisplayCaptureKit

final class MacDisplayCaptureSessionTests: XCTestCase {
    func testFactoryCreatesCGDisplayStreamSession() throws {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 3840,
            height: 2160,
            frameRate: 120,
            pixelFormat: 0x42475241,
            backend: .cgDisplayStream,
            dynamicRangeMode: .hdrCanonical
        )

        let session = try MDKCaptureSessionFactory.makeSession(configuration: configuration)

        XCTAssertEqual(session.backend, .cgDisplayStream)
        XCTAssertEqual(session.configuration.displayID, 77)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.statistics, .zero)
    }

    func testFactoryCreatesAVFoundationSession() throws {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 1920,
            height: 1080,
            frameRate: 60,
            pixelFormat: 0x42475241,
            backend: .avFoundation,
            dynamicRangeMode: .sdr
        )
        let session = try MDKCaptureSessionFactory.makeSession(configuration: configuration)

        XCTAssertEqual(session.backend, .avFoundation)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.statistics, .zero)
    }

    func testAVFoundationScreenInputConfigurationDisablesCursorAndMouseClickHighlights() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 3840,
            height: 2160,
            frameRate: 120,
            pixelFormat: 0x78343230,
            backend: .avFoundation,
            dynamicRangeMode: .hdrCanonical
        )

        let screenInputConfiguration = makeMDKAVFoundationScreenInputConfiguration(for: configuration)

        XCTAssertEqual(screenInputConfiguration.minFrameDuration, CMTime.zero)
        XCTAssertFalse(screenInputConfiguration.capturesCursor)
        XCTAssertFalse(screenInputConfiguration.capturesMouseClicks)
    }

    func testAVFoundationScreenInputConfigurationUsesExplicitFrameDurationAtSixtyFPSOrLower() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 1920,
            height: 1080,
            frameRate: 60,
            pixelFormat: 0x42475241,
            backend: .avFoundation,
            dynamicRangeMode: .sdr
        )

        let screenInputConfiguration = makeMDKAVFoundationScreenInputConfiguration(for: configuration)

        XCTAssertEqual(screenInputConfiguration.minFrameDuration, CMTime(value: 1, timescale: 60))
    }

    func testAVFoundationVideoOutputConfigurationRequestsIOSurfaceBackedMetalCompatibleFrames() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 3840,
            height: 2160,
            frameRate: 120,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            backend: .avFoundation,
            dynamicRangeMode: .hdrCanonical
        )

        let outputConfiguration = makeMDKAVFoundationVideoOutputConfiguration(for: configuration)

        XCTAssertEqual(
            outputConfiguration.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber,
            NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        )
        XCTAssertEqual(
            outputConfiguration.videoSettings[kCVPixelBufferWidthKey as String] as? NSNumber,
            NSNumber(value: 3840)
        )
        XCTAssertEqual(
            outputConfiguration.videoSettings[kCVPixelBufferHeightKey as String] as? NSNumber,
            NSNumber(value: 2160)
        )
        XCTAssertEqual(
            outputConfiguration.videoSettings[kCVPixelBufferMetalCompatibilityKey as String] as? Bool,
            true
        )
        XCTAssertNotNil(outputConfiguration.videoSettings[kCVPixelBufferIOSurfacePropertiesKey as String])
        XCTAssertEqual(outputConfiguration.alwaysDiscardsLateVideoFrames, true)
    }

    func testStopIsSafeBeforeStart() throws {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 2560,
            height: 1440,
            frameRate: 120,
            pixelFormat: 0x42475241,
            backend: .cgDisplayStream,
            dynamicRangeMode: .hdrCanonical
        )

        let session = try MDKCaptureSessionFactory.makeSession(configuration: configuration)
        session.stop()

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.statistics, .zero)
    }
}
