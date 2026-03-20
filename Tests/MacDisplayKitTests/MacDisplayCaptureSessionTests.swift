import XCTest
@testable import MacDisplayKit

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

    func testFactoryRejectsUnsupportedAVFoundationSessionCreation() {
        let configuration = MDKCaptureConfiguration(
            displayID: 77,
            width: 1920,
            height: 1080,
            frameRate: 60,
            pixelFormat: 0x42475241,
            backend: .avFoundation,
            dynamicRangeMode: .sdr
        )

        XCTAssertThrowsError(try MDKCaptureSessionFactory.makeSession(configuration: configuration)) { error in
            XCTAssertEqual(error as? MDKCaptureSessionError, .unsupportedBackend(.avFoundation))
        }
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
