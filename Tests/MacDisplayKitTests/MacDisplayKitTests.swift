import XCTest
import CoreVideo
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

    func testPrivateCaptureCapabilitiesModelHardwareSurfaceAndExtendedRangeHints() {
        let capabilities = MDKPrivateCaptureCapabilities(
            desktopCaptureAvailable: false,
            displayIOSurfaceCaptureAvailable: false,
            displayIOSurfaceCaptureWithOptionsAvailable: true,
            extendedRangeOptionAvailable: true
        )

        XCTAssertTrue(capabilities.hasAnyHardwareCaptureSurface)
        XCTAssertTrue(capabilities.supportsIOSurfaceDisplayCapture)
        XCTAssertTrue(capabilities.supportsHDRHardwareCaptureHints)
    }

    func testPrivateCaptureCapabilityProbeReturnsConsistentHardwareSurfaceFlags() {
        let capabilities = MDKCapabilityMatrix.privateCaptureCapabilities()

        XCTAssertEqual(
            capabilities.hasAnyHardwareCaptureSurface,
            capabilities.desktopCaptureAvailable ||
                capabilities.displayIOSurfaceCaptureAvailable ||
                capabilities.displayIOSurfaceCaptureWithOptionsAvailable
        )
        XCTAssertEqual(
            capabilities.supportsIOSurfaceDisplayCapture,
            capabilities.displayIOSurfaceCaptureAvailable ||
                capabilities.displayIOSurfaceCaptureWithOptionsAvailable
        )
        if capabilities.supportsHDRHardwareCaptureHints {
            XCTAssertTrue(capabilities.supportsIOSurfaceDisplayCapture)
            XCTAssertTrue(capabilities.extendedRangeOptionAvailable)
        }
    }

    func testPrivateCapturePrototypePlannerPrefersIOSurfacePathWithOptionsWhenAvailable() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: true,
                displayIOSurfaceCaptureWithOptionsAvailable: true,
                extendedRangeOptionAvailable: true
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .displayIOSurfaceWithOptions)
        XCTAssertTrue(plan.readyForIOSurfacePrototype)
        XCTAssertEqual(plan.capabilities.supportsHDRHardwareCaptureHints, true)
    }

    func testPrivateCapturePrototypePlannerFallsBackToPlainIOSurface() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: true,
                displayIOSurfaceCaptureWithOptionsAvailable: false,
                extendedRangeOptionAvailable: false
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .displayIOSurface)
        XCTAssertTrue(plan.readyForIOSurfacePrototype)
    }

    func testPrivateCapturePrototypePlannerFallsBackToDesktopCaptureWhenNeeded() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: false,
                displayIOSurfaceCaptureWithOptionsAvailable: false,
                extendedRangeOptionAvailable: false
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .desktopCapture)
        XCTAssertFalse(plan.readyForIOSurfacePrototype)
    }

    func testPrivateCapturePrototypePlannerReportsUnavailableWhenNoPrivateSurfaceExists() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: false,
                displayIOSurfaceCaptureAvailable: false,
                displayIOSurfaceCaptureWithOptionsAvailable: false,
                extendedRangeOptionAvailable: false
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .unavailable)
        XCTAssertFalse(plan.readyForIOSurfacePrototype)
    }

    func testOptimizationTargetsInclude4KHDR120CaptureOnlyBaseline() {
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly

        XCTAssertEqual(target.width, 3840)
        XCTAssertEqual(target.height, 2160)
        XCTAssertEqual(target.frameRate, 120)
        XCTAssertEqual(target.dynamicRangeMode, .hdrCanonical)
        XCTAssertEqual(target.recommendedBackend, .avFoundation)
        XCTAssertFalse(target.requiresVirtualDisplay)
    }

    func testCaptureOnlyValidationTargetsCoverRefreshRangeAndDynamicRangeDiagnostics() {
        let targets = MDKCaptureOptimizationTargets.captureOnlyValidationTargets

        XCTAssertEqual(
            targets.map(\.identifier),
            [
                "uhd-hdr-120-capture-only",
                "uhd-hdr-60-capture-only",
                "uhd-sdr-120-capture-only",
                "qhd-hdr-120-capture-only",
            ]
        )
        XCTAssertEqual(targets[1].frameRate, 60)
        XCTAssertEqual(targets[2].dynamicRangeMode, .sdr)
        XCTAssertEqual(targets[3].width, 2560)
        XCTAssertFalse(targets.contains(where: \.requiresVirtualDisplay))
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
        let configuration = target.makeConfiguration(displayID: 77)

        XCTAssertEqual(configuration.displayID, 77)
        XCTAssertEqual(configuration.width, 3840)
        XCTAssertEqual(configuration.height, 2160)
        XCTAssertEqual(configuration.frameRate, 120)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(configuration.backend, .avFoundation)
        XCTAssertEqual(configuration.dynamicRangeMode, .hdrCanonical)
    }

    func testOptimizationTargetExposesBenchmarkPixelFormat() {
        XCTAssertEqual(
            MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly.benchmarkPixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKCaptureOptimizationTargets.uhdSDR120CaptureOnly.benchmarkPixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testBenchmarkPlannerPrioritizesRecommendedPrimaryBackend() {
        let display = MDKDisplayDescriptor(id: 77, name: "77", localizedName: "Test Display")
        let target = MDKCaptureOptimizationTargets.uhdHDR120CaptureOnly
        let availability = MDKCaptureBackendAvailability(
            screenCaptureAccessAuthorized: true,
            avFoundationAvailable: true,
            cgDisplayStreamAvailable: true
        )
        let plan = MDKCaptureBenchmarkPlanner.plan(
            for: display,
            target: target,
            availability: availability
        )

        XCTAssertEqual(plan.intent, .validateDefaultBackend)
        XCTAssertTrue(plan.screenCaptureAccessAuthorized)
        XCTAssertEqual(plan.candidates.map(\.backend), [.avFoundation, .cgDisplayStream])
        XCTAssertEqual(plan.preferredCandidate?.backend, .avFoundation)
        XCTAssertEqual(
            plan.candidates.first?.reason,
            "AVFoundation capture is available and should be benchmarked first as the default native capture backend."
        )
        XCTAssertEqual(
            plan.candidates.last?.reason,
            "CGDisplayStream capture is available and should be benchmarked as an alternate native capture backend."
        )
    }
}
