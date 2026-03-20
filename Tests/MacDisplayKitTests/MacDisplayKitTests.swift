import XCTest
@testable import MacDisplayKit

final class MacDisplayKitTests: XCTestCase {
    func testVersionStringIsPresent() {
        XCTAssertFalse(MDKFrameworkInfo.versionString().isEmpty)
    }

    func testImplementationLanguagesIncludeSwiftAndObjectiveCpp() {
        XCTAssertTrue(MDKFrameworkInfo.implementationLanguages().contains("Swift"))
        XCTAssertTrue(MDKFrameworkInfo.implementationLanguages().contains("Objective-C++"))
    }

    func testPlannedModulesAreDeclared() {
        XCTAssertGreaterThanOrEqual(MDKFrameworkInfo.plannedModules().count, 4)
    }

    func testCaptureIsStandaloneAndVirtualDisplayIsOptional() {
        XCTAssertTrue(MDKCapabilityMatrix.captureIsStandalone)
        XCTAssertTrue(MDKCapabilityMatrix.virtualDisplayIsOptional)
    }

    func testOptimizationTargetsInclude4KHDR120CaptureOnlyBaseline() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly

        XCTAssertEqual(target.width, 3840)
        XCTAssertEqual(target.height, 2160)
        XCTAssertEqual(target.frameRate, 120)
        XCTAssertEqual(target.dynamicRangeMode, .hdrCanonical)
        XCTAssertEqual(target.recommendedBackend, .screenCaptureKit)
        XCTAssertFalse(target.requiresVirtualDisplay)
    }

    func testOptimizationTargetsIncludeVirtualDisplayVariants() {
        let uhdVirtual = MDKCaptureOptimizationTargets.uhdHDR120VirtualDisplay
        let qhdVirtual = MDKCaptureOptimizationTargets.qhdHDR120VirtualDisplay

        XCTAssertTrue(uhdVirtual.requiresVirtualDisplay)
        XCTAssertTrue(qhdVirtual.requiresVirtualDisplay)
        XCTAssertEqual(uhdVirtual.frameRate, 120)
        XCTAssertEqual(qhdVirtual.frameRate, 120)
        XCTAssertEqual(uhdVirtual.dynamicRangeMode, .hdrCanonical)
        XCTAssertEqual(qhdVirtual.dynamicRangeMode, .hdrCanonical)
    }

    func testOptimizationTargetCanProduceCaptureConfiguration() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let configuration = target.makeConfiguration(displayID: 77, pixelFormat: 0x78343230)

        XCTAssertEqual(configuration.displayID, 77)
        XCTAssertEqual(configuration.width, 3840)
        XCTAssertEqual(configuration.height, 2160)
        XCTAssertEqual(configuration.frameRate, 120)
        XCTAssertEqual(configuration.pixelFormat, 0x78343230)
        XCTAssertEqual(configuration.backend, .screenCaptureKit)
        XCTAssertEqual(configuration.dynamicRangeMode, .hdrCanonical)
    }
}
