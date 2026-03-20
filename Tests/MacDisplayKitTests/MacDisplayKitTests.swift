import XCTest
import CoreVideo
@testable import MacDisplayKit
@testable import MacDisplayCaptureKit

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
            displayIOSurfaceProxyCaptureAvailable: false,
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
                displayIOSurfaceProxyCaptureAvailable: false,
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
                displayIOSurfaceProxyCaptureAvailable: false,
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
                displayIOSurfaceProxyCaptureAvailable: false,
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
                displayIOSurfaceProxyCaptureAvailable: false,
                extendedRangeOptionAvailable: false
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .unavailable)
        XCTAssertFalse(plan.readyForIOSurfacePrototype)
    }

    func testPrivateCaptureProbeResultRoundTripsThroughJSON() throws {
        let result = MDKPrivateCaptureProbeResult(
            entryPoint: .displayIOSurfaceWithOptions,
            displayID: 77,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            bytesPerRow: 15360,
            pixelFormat: kCVPixelFormatType_32BGRA,
            sampleWord: 0xDEADBEEF,
            captureValue: 0x12345678,
            status: 0,
            surfacePopulated: true,
            requestedExtendedRange: false,
            extendedRangeApplied: false,
            proxiedFrameAvailable: nil,
            notes: [
                "Uses the private SDR-safe probe path."
            ]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MDKPrivateCaptureProbeResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testPrivateCaptureProbeResultParsesShimDictionary() throws {
        let payload: NSDictionary = [
            "entryPoint": "cgshw-display-iosurface-with-options",
            "displayID": NSNumber(value: 88),
            "surfaceWidth": NSNumber(value: 2560),
            "surfaceHeight": NSNumber(value: 1440),
            "bytesPerRow": NSNumber(value: 10240),
            "pixelFormat": NSNumber(value: kCVPixelFormatType_32BGRA),
            "sampleWord": NSNumber(value: 1234),
            "captureValue": NSNumber(value: 5678),
            "status": NSNumber(value: 0),
            "surfacePopulated": NSNumber(value: true),
            "requestedExtendedRange": NSNumber(value: false),
            "extendedRangeApplied": NSNumber(value: false),
            "proxiedFrameAvailable": NSNumber(value: true),
            "notes": ["payload parsed"]
        ]

        let result = try MDKPrivateCaptureProbeResult(shimDictionary: payload)
        XCTAssertEqual(result.entryPoint, .displayIOSurfaceWithOptions)
        XCTAssertEqual(result.displayID, 88)
        XCTAssertEqual(result.surfaceWidth, 2560)
        XCTAssertEqual(result.surfaceHeight, 1440)
        XCTAssertEqual(result.bytesPerRow, 10240)
        XCTAssertEqual(result.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(result.sampleWord, 1234)
        XCTAssertEqual(result.captureValue, 5678)
        XCTAssertTrue(result.surfacePopulated)
        XCTAssertEqual(result.proxiedFrameAvailable, true)
        XCTAssertEqual(result.notes, ["payload parsed"])
    }

    func testPrivateCaptureBenchmarkResultParsesShimDictionary() throws {
        let payload: NSDictionary = [
            "entryPoint": "cgshw-display-iosurface-with-options",
            "displayID": NSNumber(value: 99),
            "surfaceWidth": NSNumber(value: 3840),
            "surfaceHeight": NSNumber(value: 2160),
            "bytesPerRow": NSNumber(value: 15360),
            "pixelFormat": NSNumber(value: kCVPixelFormatType_32BGRA),
            "sampleWord": NSNumber(value: 4321),
            "captureValue": NSNumber(value: 8765),
            "status": NSNumber(value: 0),
            "surfacePopulated": NSNumber(value: true),
            "requestedExtendedRange": NSNumber(value: true),
            "extendedRangeApplied": NSNumber(value: true),
            "proxiedFrameAvailable": NSNumber(value: true),
            "sampleDuration": NSNumber(value: 1.25),
            "iterationCount": NSNumber(value: 150),
            "populatedFrameCount": NSNumber(value: 148),
            "observedFrameRate": NSNumber(value: 120.0),
            "populatedFrameRate": NSNumber(value: 118.4),
            "notes": ["benchmark payload parsed"]
        ]

        let result = try MDKPrivateCaptureBenchmarkResult(shimDictionary: payload)
        XCTAssertEqual(result.probe.displayID, 99)
        XCTAssertEqual(result.probe.captureValue, 8765)
        XCTAssertEqual(result.sampleDuration, 1.25, accuracy: 0.0001)
        XCTAssertEqual(result.iterationCount, 150)
        XCTAssertEqual(result.populatedFrameCount, 148)
        XCTAssertEqual(result.observedFrameRate, 120.0, accuracy: 0.0001)
        XCTAssertEqual(result.populatedFrameRate, 118.4, accuracy: 0.0001)
        XCTAssertEqual(result.probe.proxiedFrameAvailable, true)
    }

    func testPrivateCapturePrototypePlannerPrefersProxyingPathWhenAvailable() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: true,
                displayIOSurfaceCaptureWithOptionsAvailable: true,
                displayIOSurfaceProxyCaptureAvailable: true,
                extendedRangeOptionAvailable: true
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .displayIOSurfaceProxying)
        XCTAssertTrue(plan.readyForIOSurfacePrototype)
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
