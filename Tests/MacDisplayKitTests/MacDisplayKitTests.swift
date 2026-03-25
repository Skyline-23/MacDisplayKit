import XCTest
import CoreVideo
import VideoToolbox
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

    func testDownscale2xStrategyKeepsBiPlanarEncoderTargetsEvenSized() {
        let target = MDKVideoPreprocessStrategy.downscale2x.outputDimensions(
            sourceWidth: 5121,
            sourceHeight: 2881,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertEqual(target, SIMD2(2560, 1440))
    }

    func testSkyLightPixelFormatAliasesMapToExpectedCoreVideoFormats() {
        XCTAssertEqual(MDKSkyLightDisplayStreamPixelFormat.bgra.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(
            MDKSkyLightDisplayStreamPixelFormat.biPlanar420VideoRange.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKSkyLightDisplayStreamPixelFormat.biPlanar420FullRange.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(
            MDKSkyLightDisplayStreamPixelFormat.biPlanar42010VideoRange.pixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKSkyLightDisplayStreamPixelFormat.biPlanar42010FullRange.pixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }

    func testDownscaleProcessingModesExposeCodecAndPreprocessStrategy() {
        XCTAssertEqual(MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeDownscale2x.videoEncoderCodec, .hevc)
        XCTAssertEqual(MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeDownscale2x.videoPreprocessStrategy, .downscale2x)
        XCTAssertEqual(MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeH264Downscale2x.videoEncoderCodec, .h264)
        XCTAssertEqual(MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeH264Downscale2x.videoPreprocessStrategy, .downscale2x)
        XCTAssertEqual(
            MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeProResProxyExperimental.videoEncoderCodec,
            .proResProxy
        )
        XCTAssertTrue(MDKCaptureBenchmarkProcessingMode.videoToolboxEncodeProResProxyExperimental.isExperimental)
    }

    func testHEVCUsesMain10ProfileForTenBitBiPlanarInputs() {
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.defaultProfileLevel(for: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kVTProfileLevel_HEVC_Main10_AutoLevel
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.defaultProfileLevel(for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kVTProfileLevel_HEVC_Main_AutoLevel
        )
    }

    func testHEVCPrefersLowLatencyRateControlAndSingleReferenceBuffer() {
        XCTAssertTrue(MDKVideoEncoderCodec.hevc.lowLatencyRateControlSupported)
        XCTAssertEqual(MDKVideoEncoderCodec.hevc.referenceBufferCount, 1)
    }

    func testCodecPreferredInputPixelFormatsFavorEncoderFriendlyTargets() {
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.preferredInputPixelFormat(
                for: kCVPixelFormatType_32BGRA,
                hdrConfiguration: nil,
                strategy: .auto
            ),
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.preferredInputPixelFormat(
                for: kCVPixelFormatType_32BGRA,
                hdrConfiguration: .hdr10(),
                strategy: .auto
            ),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.preferredInputPixelFormat(
                for: kCVPixelFormatType_32BGRA,
                hdrConfiguration: nil,
                strategy: .yuv420v10
            ),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.hevc.preferredInputPixelFormat(
                for: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                hdrConfiguration: nil,
                strategy: .yuv420v8
            ),
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.h264.preferredInputPixelFormat(for: kCVPixelFormatType_32BGRA),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.h264.preferredInputPixelFormat(
                for: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                hdrConfiguration: nil,
                strategy: .yuv420v10
            ),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.proResProxy.preferredInputPixelFormat(for: kCVPixelFormatType_32BGRA),
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            MDKVideoEncoderCodec.proResProxy.preferredInputPixelFormat(
                for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                hdrConfiguration: nil,
                strategy: .yuv420v8
            ),
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        )
    }

    func testSkyLightDisplayStreamAutoEncoderInputStrategyPreservesAutomaticSelection() {
        let baseStreamConfiguration = MDKSkyLightDisplayStreamConfiguration(
            queueDepth: 2,
            queueProfile: .q2,
            showCursor: false,
            outputWidth: 3512,
            outputHeight: 2290,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let hevcSDRConfiguration = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: baseStreamConfiguration,
            codec: .hevc,
            targetFrameRate: 120,
            encoderInputStrategy: .auto,
            hdrConfiguration: nil
        )
        XCTAssertEqual(
            hevcSDRConfiguration.resolvedEncoderInputStrategy,
            MDKEncodedCaptureEncoderInputStrategy.auto
        )

        let hevcHDRConfiguration = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: baseStreamConfiguration,
            codec: .hevc,
            targetFrameRate: 120,
            encoderInputStrategy: .auto,
            hdrConfiguration: .hdr10()
        )
        XCTAssertEqual(
            hevcHDRConfiguration.resolvedEncoderInputStrategy,
            MDKEncodedCaptureEncoderInputStrategy.auto
        )

        let h264Configuration = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: baseStreamConfiguration,
            codec: .h264,
            targetFrameRate: 120,
            encoderInputStrategy: .auto,
            hdrConfiguration: nil
        )
        XCTAssertEqual(
            h264Configuration.resolvedEncoderInputStrategy,
            MDKEncodedCaptureEncoderInputStrategy.auto
        )

        let proResConfiguration = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: baseStreamConfiguration,
            codec: .proResProxy,
            targetFrameRate: 120,
            encoderInputStrategy: .auto,
            hdrConfiguration: nil
        )
        XCTAssertEqual(
            proResConfiguration.resolvedEncoderInputStrategy,
            MDKEncodedCaptureEncoderInputStrategy.auto
        )
    }

    func testSkyLightPendingFrameCountStaysTightForCallbackOnlyEncodedCapture() {
        let callbackOnlyQ2 = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: .panelNative(
                queueDepth: 2,
                queueProfile: .q2,
                showCursor: false,
                pixelFormat: kCVPixelFormatType_32BGRA
            ),
            codec: .hevc,
            preprocessStrategy: .none,
            targetFrameRate: 120,
            deliveryMode: .callbackOnly
        )
        let callbackOnlyQ3 = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: .panelNative(
                queueDepth: 3,
                queueProfile: .q3,
                showCursor: false,
                pixelFormat: kCVPixelFormatType_32BGRA
            ),
            codec: .hevc,
            preprocessStrategy: .none,
            targetFrameRate: 120,
            deliveryMode: .callbackOnly
        )
        let multiplexedQ2 = MDKEncodedCaptureConfiguration(
            displayID: 7,
            streamConfiguration: .panelNative(
                queueDepth: 2,
                queueProfile: .q2,
                showCursor: false,
                pixelFormat: kCVPixelFormatType_32BGRA
            ),
            codec: .hevc,
            preprocessStrategy: .none,
            targetFrameRate: 120,
            deliveryMode: .multiplexed
        )

        XCTAssertEqual(
            MDKEncodedCaptureSession.recommendedSkyLightPendingFrameCount(
                for: callbackOnlyQ2,
                queueDepth: 2
            ),
            4
        )
        XCTAssertEqual(
            MDKEncodedCaptureSession.recommendedSkyLightPendingFrameCount(
                for: callbackOnlyQ3,
                queueDepth: 3
            ),
            5
        )
        XCTAssertEqual(
            MDKEncodedCaptureSession.recommendedSkyLightPendingFrameCount(
                for: multiplexedQ2,
                queueDepth: 2
            ),
            10
        )
    }

    func testHEVCHDRNegotiationPreservesDisplayP3WhenRequested() {
        let requested = MDKVideoHDRConfiguration(
            colorPrimaries: .p3D65,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR709,
            metadataInsertionMode: .automatic,
            masteringDisplayColorVolume: .hdr10Default(),
            contentLightLevelInfo: .hdr10Default()
        )

        let negotiated = requested.negotiatedForEncodedDelivery(codec: .hevc)

        XCTAssertEqual(negotiated.colorPrimaries, .p3D65)
        XCTAssertEqual(negotiated.transferFunction, .smpteSt2084PQ)
        XCTAssertEqual(negotiated.yCbCrMatrix, .ituR709)
    }

    func testHEVCHDRNegotiationKeepsBT2020HDR10ProfilesStable() {
        let requested = MDKVideoHDRConfiguration.hdr10()
        let negotiated = requested.negotiatedForEncodedDelivery(codec: .hevc)

        XCTAssertEqual(negotiated.colorPrimaries, .ituR2020)
        XCTAssertEqual(negotiated.transferFunction, .smpteSt2084PQ)
        XCTAssertEqual(negotiated.yCbCrMatrix, .ituR2020)
    }

    func testDefaultRawProcessingMatrixKeepsOptInCodecsOutOfBand() {
        XCTAssertFalse(MDKSkyLightDisplayStreamProcessingMatrix.defaultProcessingModes.contains(.videoToolboxEncodeProResProxyExperimental))
        XCTAssertTrue(MDKSkyLightDisplayStreamProcessingMatrix.optInProcessingModes.contains(.videoToolboxEncodeProResProxyExperimental))
    }

    func testRawTuningMatrixPrefersRealtimeFloorBeforeCadenceClass() {
        let belowFloorCandidate = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "below-floor",
                minimumFrameTime: 1.0 / 240.0,
                queueDepth: 3,
                showCursor: false
            ),
            result: MDKSkyLightDisplayStreamBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                sampleDuration: 1.0,
                callbackCount: 55,
                completeFrameCount: 55,
                observedFrameRate: 55.0,
                requested120LikeProperties: true,
                requestedMinimumFrameTime: 1.0 / 240.0,
                requestedQueueDepth: 3,
                requestedShowCursor: false,
                appliedPropertyCount: 3,
                surfaceWidth: 5120,
                surfaceHeight: 2880,
                pixelFormat: kCVPixelFormatType_32BGRA,
                intervalCount: 54,
                minIntervalMilliseconds: 8.333,
                maxIntervalMilliseconds: 20.0,
                intervalHistogram: ["8.3ms": 40],
                cadenceClassification: "120hz-like",
                frameStatusHistogram: ["frame-complete": 55],
                notes: []
            )
        )
        let aboveFloorCandidate = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "above-floor",
                minimumFrameTime: 0,
                queueDepth: 3,
                showCursor: false
            ),
            result: MDKSkyLightDisplayStreamBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                sampleDuration: 1.0,
                callbackCount: 61,
                completeFrameCount: 61,
                observedFrameRate: 61.0,
                requested120LikeProperties: false,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 3,
                requestedShowCursor: false,
                appliedPropertyCount: 3,
                surfaceWidth: 5120,
                surfaceHeight: 2880,
                pixelFormat: kCVPixelFormatType_32BGRA,
                intervalCount: 60,
                minIntervalMilliseconds: 16.667,
                maxIntervalMilliseconds: 17.0,
                intervalHistogram: ["16.7ms": 60],
                cadenceClassification: "60hz-like",
                frameStatusHistogram: ["frame-complete": 61],
                notes: []
            )
        )

        XCTAssertEqual(
            MDKSkyLightDisplayStreamTuningMatrix.bestEvaluationIndex(
                for: [belowFloorCandidate, aboveFloorCandidate]
            ),
            1
        )
    }

    func testPrivateCaptureCapabilitiesModelHardwareSurfaceAndExtendedRangeHints() {
        let capabilities = MDKPrivateCaptureCapabilities(
            desktopCaptureAvailable: false,
            displayIOSurfaceCaptureAvailable: false,
            displayIOSurfaceCaptureWithOptionsAvailable: true,
            displayIOSurfaceProxyCaptureAvailable: false,
            displayStreamProxyAvailable: false,
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
                capabilities.displayIOSurfaceCaptureWithOptionsAvailable ||
                capabilities.displayIOSurfaceProxyCaptureAvailable ||
                capabilities.displayStreamProxyAvailable
        )
        XCTAssertEqual(
            capabilities.supportsIOSurfaceDisplayCapture,
            capabilities.displayIOSurfaceCaptureAvailable ||
                capabilities.displayIOSurfaceCaptureWithOptionsAvailable ||
                capabilities.displayIOSurfaceProxyCaptureAvailable
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
                displayStreamProxyAvailable: false,
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
                displayStreamProxyAvailable: false,
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
                displayStreamProxyAvailable: false,
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
                displayStreamProxyAvailable: false,
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
            portStatus: nil,
            portTypeStatus: nil,
            portType: nil,
            portMessageCount: nil,
            portQueueLimit: nil,
            portSequenceNumber: nil,
            portMessagesWaiting: nil,
            streamPropertiesProfile: nil,
            portMode: nil,
            selectiveSharingMode: nil,
            selectiveSharingHigh: nil,
            selectiveSharingLow: nil,
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
            "portStatus": NSNumber(value: 0),
            "portTypeStatus": NSNumber(value: 0),
            "portType": NSNumber(value: 17),
            "portMessageCount": NSNumber(value: 3),
            "portQueueLimit": NSNumber(value: 5),
            "portSequenceNumber": NSNumber(value: 7),
            "portMessagesWaiting": NSNumber(value: true),
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
        XCTAssertEqual(result.portStatus, 0)
        XCTAssertEqual(result.portTypeStatus, 0)
        XCTAssertEqual(result.portType, 17)
        XCTAssertEqual(result.portMessageCount, 3)
        XCTAssertEqual(result.portQueueLimit, 5)
        XCTAssertEqual(result.portSequenceNumber, 7)
        XCTAssertEqual(result.portMessagesWaiting, true)
        XCTAssertEqual(result.streamPropertiesProfile, nil)
        XCTAssertEqual(result.notes, ["payload parsed"])
    }

    func testPrivateCaptureProbeResultParsesDisplayStreamConfigurationFields() throws {
        let payload: NSDictionary = [
            "entryPoint": "sls-display-stream-proxying",
            "displayID": NSNumber(value: 2),
            "surfaceWidth": NSNumber(value: 5120),
            "surfaceHeight": NSNumber(value: 2880),
            "bytesPerRow": NSNumber(value: 0),
            "pixelFormat": NSNumber(value: kCVPixelFormatType_32BGRA),
            "sampleWord": NSNumber(value: 0),
            "status": NSNumber(value: 1002),
            "surfacePopulated": NSNumber(value: false),
            "requestedExtendedRange": NSNumber(value: false),
            "extendedRangeApplied": NSNumber(value: false),
            "streamPropertiesProfile": "full-public",
            "portMode": "receive-only",
            "selectiveSharingMode": "zero",
            "selectiveSharingHigh": NSNumber(value: UInt64(0)),
            "selectiveSharingLow": NSNumber(value: UInt64(0)),
            "notes": ["stream probe payload parsed"]
        ]

        let result = try MDKPrivateCaptureProbeResult(shimDictionary: payload)
        XCTAssertEqual(result.entryPoint, .displayStreamProxying)
        XCTAssertEqual(result.streamPropertiesProfile, "full-public")
        XCTAssertEqual(result.portMode, "receive-only")
        XCTAssertEqual(result.selectiveSharingMode, "zero")
        XCTAssertEqual(result.selectiveSharingHigh, 0)
        XCTAssertEqual(result.selectiveSharingLow, 0)
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
            "portMessageCount": NSNumber(value: 2),
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
        XCTAssertEqual(result.probe.portMessageCount, 2)
    }

    func testSkyLightDisplayStreamBenchmarkResultRoundTripsThroughJSON() throws {
        let result = MDKSkyLightDisplayStreamBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            sampleDuration: 2.0,
            callbackCount: 200,
            completeFrameCount: 193,
            observedFrameRate: 96.5,
            requested120LikeProperties: true,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 3,
            requestedShowCursor: false,
            appliedPropertyCount: 3,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 192,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 62.499,
            stallCountOver16Milliseconds: 40,
            stallCountOver33Milliseconds: 2,
            stallCountOver100Milliseconds: 0,
            longGapRatioOver16Milliseconds: 40.0 / 192.0,
            longGapRatioOver33Milliseconds: 2.0 / 192.0,
            longGapRatioOver100Milliseconds: 0.0,
            intervalHistogram: ["8.3ms": 101],
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 193],
            notes: ["raw benchmark payload"]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MDKSkyLightDisplayStreamBenchmarkResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testSkyLightDisplayStreamBenchmarkResultParsesShimDictionary() throws {
        let payload: NSDictionary = [
            "displayID": NSNumber(value: 2),
            "status": NSNumber(value: 0),
            "stopStatus": NSNumber(value: 0),
            "sampleDuration": NSNumber(value: 2.0),
            "callbackCount": NSNumber(value: 200),
            "completeFrameCount": NSNumber(value: 193),
            "observedFrameRate": NSNumber(value: 96.5),
            "requested120LikeProperties": NSNumber(value: true),
            "requestedMinimumFrameTime": NSNumber(value: 1.0 / 240.0),
            "requestedQueueDepth": NSNumber(value: 3),
            "requestedShowCursor": NSNumber(value: false),
            "appliedPropertyCount": NSNumber(value: 3),
            "surfaceWidth": NSNumber(value: 5120),
            "surfaceHeight": NSNumber(value: 2880),
            "pixelFormat": NSNumber(value: kCVPixelFormatType_32BGRA),
            "intervalCount": NSNumber(value: 192),
            "minIntervalMilliseconds": NSNumber(value: 4.167),
            "maxIntervalMilliseconds": NSNumber(value: 62.499),
            "stallCountOver16Milliseconds": NSNumber(value: 40),
            "stallCountOver33Milliseconds": NSNumber(value: 2),
            "stallCountOver100Milliseconds": NSNumber(value: 0),
            "longGapRatioOver16Milliseconds": NSNumber(value: 40.0 / 192.0),
            "longGapRatioOver33Milliseconds": NSNumber(value: 2.0 / 192.0),
            "longGapRatioOver100Milliseconds": NSNumber(value: 0.0),
            "intervalHistogram": ["8.3ms": NSNumber(value: 101), "12.5ms": NSNumber(value: 40)],
            "cadenceClassification": "120hz-like",
            "frameStatusHistogram": ["frame-complete": NSNumber(value: 193), "frame-idle": NSNumber(value: 7)],
            "notes": ["raw benchmark payload"]
        ]

        let result = try MDKSkyLightDisplayStreamBenchmarkResult(shimDictionary: payload)
        XCTAssertEqual(result.displayID, 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stopStatus, 0)
        XCTAssertEqual(result.completeFrameCount, 193)
        XCTAssertEqual(result.observedFrameRate, 96.5)
        XCTAssertTrue(result.requested120LikeProperties)
        XCTAssertEqual(result.requestedQueueDepth, 3)
        XCTAssertEqual(result.appliedPropertyCount, 3)
        XCTAssertEqual(result.surfaceWidth, 5120)
        XCTAssertEqual(result.surfaceHeight, 2880)
        XCTAssertEqual(result.stallCountOver16Milliseconds, 40)
        XCTAssertEqual(result.stallCountOver33Milliseconds, 2)
        XCTAssertEqual(result.stallCountOver100Milliseconds, 0)
        XCTAssertEqual(result.longGapRatioOver16Milliseconds, 40.0 / 192.0, accuracy: 0.000_001)
        XCTAssertEqual(result.intervalHistogram["8.3ms"], 101)
        XCTAssertEqual(result.frameStatusHistogram["frame-idle"], 7)
        XCTAssertEqual(result.cadenceClassification, "120hz-like")
    }

    func testSkyLightDisplayStreamBenchmarkResultCanAppendNotes() {
        let result = MDKSkyLightDisplayStreamBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            sampleDuration: 1.0,
            callbackCount: 10,
            completeFrameCount: 9,
            observedFrameRate: 9.0,
            requested120LikeProperties: false,
            requestedMinimumFrameTime: 0.0,
            requestedQueueDepth: 3,
            requestedShowCursor: false,
            appliedPropertyCount: 3,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 8,
            minIntervalMilliseconds: 8.333,
            maxIntervalMilliseconds: 33.333,
            stallCountOver16Milliseconds: 1,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            longGapRatioOver16Milliseconds: 0.125,
            longGapRatioOver33Milliseconds: 0.0,
            longGapRatioOver100Milliseconds: 0.0,
            intervalHistogram: [:],
            cadenceClassification: "coalesced-or-mixed",
            frameStatusHistogram: [:],
            notes: ["base"]
        )

        let appended = result.appendingNotes(["hostLoad/WindowServer pcpu=40.0 pmem=0.7"])

        XCTAssertEqual(appended.notes, ["base", "hostLoad/WindowServer pcpu=40.0 pmem=0.7"])
        XCTAssertEqual(appended.stallCountOver16Milliseconds, result.stallCountOver16Milliseconds)
    }

    func testRequest120LikeCandidateUsesRetunedQ1Configuration() {
        let candidate = MDKSkyLightDisplayStreamTuningMatrix.request120LikeCandidate

        XCTAssertEqual(candidate.identifier, "min-frame-240hz-q1")
        XCTAssertEqual(candidate.minimumFrameTime, 1.0 / 240.0, accuracy: 0.000_001)
        XCTAssertEqual(candidate.queueDepth, 1)
        XCTAssertFalse(candidate.showCursor)
    }

    func testSkyLightConfigurationWrapsTuningAndOptionalOverrides() {
        let configuration = MDKSkyLightDisplayStreamConfiguration.panelNative(
            queueDepth: 2,
            showCursor: false,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        XCTAssertEqual(configuration.queueDepth, 2)
        XCTAssertFalse(configuration.showCursor)
        XCTAssertNil(configuration.outputWidth)
        XCTAssertNil(configuration.outputHeight)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.resolvedQueueDepth, 2)
        XCTAssertFalse(configuration.resolvedShowCursor)
        XCTAssertEqual(configuration.resolvedPixelFormatOverride, kCVPixelFormatType_32BGRA)
    }

    func testSkyLightConfigurationPanelNativeDefaultsToBaselineQ2() {
        let configuration = MDKSkyLightDisplayStreamConfiguration.panelNative()

        XCTAssertEqual(configuration.queueDepth, 2)
        XCTAssertFalse(configuration.showCursor)
        XCTAssertEqual(configuration.resolvedQueueDepth, 2)
        XCTAssertFalse(configuration.resolvedShowCursor)
    }

    func testProcessingBenchmarkDefaultsEncoderHintTo120EvenFor240HzRawRequests() {
        let derivedHint = MDKSkyLightDisplayStreamProcessingBenchmark.resolvedTargetFrameRateHint(
            targetFrameRate: nil,
            requestedMinimumFrameTime: 1.0 / 240.0
        )
        let explicitHint = MDKSkyLightDisplayStreamProcessingBenchmark.resolvedTargetFrameRateHint(
            targetFrameRate: 144,
            requestedMinimumFrameTime: 0
        )

        XCTAssertEqual(derivedHint, 120)
        XCTAssertEqual(explicitHint, 144)
    }

    func testTuningAdvisorPrefersLowerQueueDepthForProRes() {
        let candidates = MDKSkyLightDisplayStreamTuningAdvisor.recommendedCandidates(
            for: .videoToolboxEncodeProResProxyExperimental
        )

        XCTAssertEqual(candidates.map(\.identifier), ["baseline-q2", "baseline-q1", "baseline-q3"])
    }

    func testTuningAdvisorKeeps120LikeCandidateForHEVC() {
        let candidates = MDKSkyLightDisplayStreamTuningAdvisor.recommendedCandidates(
            for: .videoToolboxEncode,
            targetFrameRate: 120
        )

        XCTAssertEqual(candidates.first?.identifier, "baseline-q2")
        XCTAssertEqual(candidates.dropFirst().first?.identifier, "baseline-q3")
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "baseline-q1" }))
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "min-frame-240hz-q1" }))
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "baseline-q4" }))
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "baseline-q8" }))
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "min-frame-240hz-q8" }))
        XCTAssertTrue(candidates.contains(where: { $0.identifier == "legacy-120hz-request" }))
    }

    func testTuningAdvisorKeepsHighRefreshCandidatesOutOf60FPSHEVCList() {
        let candidates = MDKSkyLightDisplayStreamTuningAdvisor.recommendedCandidates(
            for: .videoToolboxEncode,
            targetFrameRate: 60
        )

        XCTAssertFalse(candidates.contains(where: { $0.identifier == "baseline-q8" }))
        XCTAssertFalse(candidates.contains(where: { $0.identifier == "min-frame-240hz-q8" }))
        XCTAssertFalse(candidates.contains(where: { $0.identifier == "legacy-120hz-request" }))
    }

    func testSkyLightDisplayStreamProcessingBenchmarkResultRoundTripsThroughJSON() throws {
        let result = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 200,
            completeFrameCount: 193,
            observedFrameRate: 96.5,
            processedFrameCount: 190,
            processingFailureCount: 3,
            processingErrorHistogram: ["example": 3],
            processedFrameRate: 95.0,
            processedFrameRatio: 0.984,
            outputCallbackCount: 96,
            completedOutputFrameCount: 90,
            completedOutputFrameRate: 45.0,
            completedOutputFrameRatio: 90.0 / 190.0,
            outputCallbackStatusHistogram: ["noErr": 96],
            outputCallbackLatencyHistogram: ["1.2ms": 90, "2.4ms": 6],
            minOutputCallbackLatencyMilliseconds: 1.2,
            maxOutputCallbackLatencyMilliseconds: 2.4,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 192,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 62.499,
            intervalHistogram: ["8.3ms": 101],
            stallCountOver16Milliseconds: 6,
            stallCountOver33Milliseconds: 1,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 193],
            notes: ["raw processing benchmark payload"]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MDKSkyLightDisplayStreamProcessingBenchmarkResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testSkyLightDisplayStreamTuningMatrixPrefers120LikeCandidate() {
        let mixedResult = MDKSkyLightDisplayStreamBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            sampleDuration: 2.0,
            callbackCount: 200,
            completeFrameCount: 200,
            observedFrameRate: 105.0,
            requested120LikeProperties: false,
            requestedMinimumFrameTime: 0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            appliedPropertyCount: 3,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 199,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 62.499,
            intervalHistogram: ["8.3ms": 90],
            cadenceClassification: "coalesced-or-mixed",
            frameStatusHistogram: ["frame-complete": 200],
            notes: []
        )
        let fastCandidate = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "baseline-q8",
                minimumFrameTime: 0,
                queueDepth: 8,
                showCursor: false
            ),
            result: mixedResult
        )

        let oneTwentyLikeResult = MDKSkyLightDisplayStreamBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            sampleDuration: 2.0,
            callbackCount: 198,
            completeFrameCount: 198,
            observedFrameRate: 102.0,
            requested120LikeProperties: false,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 3,
            requestedShowCursor: false,
            appliedPropertyCount: 3,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 197,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 62.499,
            intervalHistogram: ["8.3ms": 100],
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 198],
            notes: []
        )
        let oneTwentyLikeCandidate = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "min-frame-240hz-q3",
                minimumFrameTime: 1.0 / 240.0,
                queueDepth: 3,
                showCursor: false
            ),
            result: oneTwentyLikeResult
        )

        let bestIndex = MDKSkyLightDisplayStreamTuningMatrix.bestEvaluationIndex(
            for: [fastCandidate, oneTwentyLikeCandidate]
        )

        XCTAssertEqual(bestIndex, 1)
    }

    func testSkyLightDisplayStreamTuningMatrixReportReturnsBestEvaluation() {
        let evaluation = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "baseline-q8",
                minimumFrameTime: 0,
                queueDepth: 8,
                showCursor: false
            ),
            result: MDKSkyLightDisplayStreamBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                sampleDuration: 2.0,
                callbackCount: 200,
                completeFrameCount: 200,
                observedFrameRate: 100.0,
                requested120LikeProperties: false,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 8,
                requestedShowCursor: false,
                appliedPropertyCount: 3,
                surfaceWidth: 5120,
                surfaceHeight: 2880,
                pixelFormat: kCVPixelFormatType_32BGRA,
                intervalCount: 199,
                minIntervalMilliseconds: 4.167,
                maxIntervalMilliseconds: 62.499,
                intervalHistogram: ["8.3ms": 95],
                cadenceClassification: "120hz-like",
                frameStatusHistogram: ["frame-complete": 200],
                notes: []
            )
        )

        let report = MDKSkyLightDisplayStreamTuningMatrixReport(
            displayID: 2,
            sampleDuration: 2.0,
            useMetalStimulus: true,
            evaluations: [evaluation],
            bestEvaluationIndex: 0,
            notes: []
        )

        XCTAssertEqual(report.bestEvaluation, evaluation)
    }

    func testSkyLightDisplayStreamTuningMatrixPrefersLowerStallCandidateWhenFrameRateIsClose() {
        let stableEvaluation = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "baseline-q2",
                minimumFrameTime: 0,
                queueDepth: 2,
                showCursor: false
            ),
            result: MDKSkyLightDisplayStreamBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                sampleDuration: 2.0,
                callbackCount: 182,
                completeFrameCount: 182,
                observedFrameRate: 91.0,
                requested120LikeProperties: false,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 2,
                requestedShowCursor: false,
                appliedPropertyCount: 3,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_32BGRA,
                intervalCount: 181,
                minIntervalMilliseconds: 8.333,
                maxIntervalMilliseconds: 18.0,
                stallCountOver16Milliseconds: 8,
                stallCountOver33Milliseconds: 0,
                stallCountOver100Milliseconds: 0,
                intervalHistogram: ["8.3ms": 120, "16.7ms": 61],
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 182],
                notes: []
            )
        )
        let burstyEvaluation = MDKSkyLightDisplayStreamTuningEvaluation(
            candidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "baseline-q4",
                minimumFrameTime: 0,
                queueDepth: 4,
                showCursor: false
            ),
            result: MDKSkyLightDisplayStreamBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                sampleDuration: 2.0,
                callbackCount: 184,
                completeFrameCount: 184,
                observedFrameRate: 92.0,
                requested120LikeProperties: false,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 4,
                requestedShowCursor: false,
                appliedPropertyCount: 3,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_32BGRA,
                intervalCount: 183,
                minIntervalMilliseconds: 4.167,
                maxIntervalMilliseconds: 41.0,
                stallCountOver16Milliseconds: 40,
                stallCountOver33Milliseconds: 6,
                stallCountOver100Milliseconds: 0,
                intervalHistogram: ["4.2ms": 80, "33.3ms": 103],
                cadenceClassification: "120hz-like",
                frameStatusHistogram: ["frame-complete": 184],
                notes: []
            )
        )

        XCTAssertEqual(
            MDKSkyLightDisplayStreamTuningMatrix.bestEvaluationIndex(for: [stableEvaluation, burstyEvaluation]),
            0
        )
    }

    func testSkyLightDisplayStreamProcessingMatrixRanksSuccessfulCandidates() throws {
        let rawControlCandidate = MDKSkyLightDisplayStreamProcessingMatrixCandidate(
            identifier: "none/baseline-q3",
            processingMode: .none,
            tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "baseline-q3",
                minimumFrameTime: 0,
                queueDepth: 3,
                showCursor: false
            )
        )
        let rawControlResult = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .none,
            videoEncoderCodec: nil,
            sampleDuration: 2.0,
            callbackCount: 200,
            completeFrameCount: 200,
            observedFrameRate: 112.0,
            processedFrameCount: 200,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 112.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: nil,
            completedOutputFrameCount: nil,
            completedOutputFrameRate: nil,
            completedOutputFrameRatio: nil,
            outputCallbackStatusHistogram: nil,
            outputCallbackLatencyHistogram: nil,
            minOutputCallbackLatencyMilliseconds: nil,
            maxOutputCallbackLatencyMilliseconds: nil,
            requestedMinimumFrameTime: 0,
            requestedQueueDepth: 3,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 199,
            minIntervalMilliseconds: 8.333,
            maxIntervalMilliseconds: 16.667,
            intervalHistogram: ["8.3ms": 200],
            stallCountOver16Milliseconds: 0,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "60hz-like",
            frameStatusHistogram: ["frame-complete": 200],
            notes: []
        )
        let winningCandidate = MDKSkyLightDisplayStreamProcessingMatrixCandidate(
            identifier: "metal-copy/min-frame-240hz-q8",
            processingMode: .metalCopy,
            tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                identifier: "min-frame-240hz-q8",
                minimumFrameTime: 1.0 / 240.0,
                queueDepth: 8,
                showCursor: false
            )
        )
        let winningResult = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .metalCopy,
            videoEncoderCodec: nil,
            sampleDuration: 2.0,
            callbackCount: 198,
            completeFrameCount: 198,
            observedFrameRate: 102.0,
            processedFrameCount: 198,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 99.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: nil,
            completedOutputFrameCount: 98,
            completedOutputFrameRate: 49.0,
            completedOutputFrameRatio: 98.0 / 198.0,
            outputCallbackStatusHistogram: nil,
            outputCallbackLatencyHistogram: nil,
            minOutputCallbackLatencyMilliseconds: nil,
            maxOutputCallbackLatencyMilliseconds: nil,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_32BGRA,
            intervalCount: 197,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 16.667,
            intervalHistogram: ["4.2ms": 198],
            stallCountOver16Milliseconds: 0,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 198],
            notes: []
        )
        let evaluations = [
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: rawControlCandidate,
                result: rawControlResult,
                errorDescription: nil
            ),
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: winningCandidate,
                result: winningResult,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations), 1)
        let report = MDKSkyLightDisplayStreamProcessingMatrixReport(
            displayID: 2,
            sampleDuration: 2.0,
            useMetalStimulus: true,
            evaluations: evaluations,
            bestEvaluationIndex: 1,
            notes: ["processing matrix report"]
        )
        XCTAssertEqual(report.bestEvaluation?.candidate, winningCandidate)

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MDKSkyLightDisplayStreamProcessingMatrixReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testProcessingMatrixPrefersRealtimeFloorBefore120LikeWishcasting() {
        let belowFloor = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncodeDownscale2x,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 110,
            completeFrameCount: 110,
            observedFrameRate: 55.0,
            processedFrameCount: 110,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 55.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 110,
            completedOutputFrameCount: 110,
            completedOutputFrameRate: 55.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 110],
            outputCallbackLatencyHistogram: [:],
            minOutputCallbackLatencyMilliseconds: 5.0,
            maxOutputCallbackLatencyMilliseconds: 9.0,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            intervalCount: 109,
            minIntervalMilliseconds: 8.333,
            maxIntervalMilliseconds: 20.0,
            intervalHistogram: ["8.3ms": 80],
            stallCountOver16Milliseconds: 4,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 110],
            notes: []
        )
        let aboveFloor = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncodeProResProxyExperimental,
            videoEncoderCodec: .proResProxy,
            sampleDuration: 2.0,
            callbackCount: 122,
            completeFrameCount: 122,
            observedFrameRate: 61.0,
            processedFrameCount: 122,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 61.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 122,
            completedOutputFrameCount: 122,
            completedOutputFrameRate: 61.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 122],
            outputCallbackLatencyHistogram: [:],
            minOutputCallbackLatencyMilliseconds: 7.0,
            maxOutputCallbackLatencyMilliseconds: 10.0,
            requestedMinimumFrameTime: 0,
            requestedQueueDepth: 3,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            intervalCount: 121,
            minIntervalMilliseconds: 16.667,
            maxIntervalMilliseconds: 17.0,
            intervalHistogram: ["16.7ms": 121],
            stallCountOver16Milliseconds: 121,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "60hz-like",
            frameStatusHistogram: ["frame-complete": 122],
            notes: []
        )

        let evaluations = [
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "below-floor",
                    processingMode: .videoToolboxEncodeDownscale2x,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "min-frame-240hz-q8",
                        minimumFrameTime: 1.0 / 240.0,
                        queueDepth: 8,
                        showCursor: false
                    )
                ),
                result: belowFloor,
                errorDescription: nil
            ),
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "above-floor",
                    processingMode: .videoToolboxEncodeProResProxyExperimental,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "baseline-q3",
                        minimumFrameTime: 0,
                        queueDepth: 3,
                        showCursor: false
                    )
                ),
                result: aboveFloor,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations), 1)
    }

    func testProcessingMatrixPrefersLowerStallEncoderCandidateWhenRealtimeFloorMatches() {
        let stable = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 150,
            completeFrameCount: 150,
            observedFrameRate: 75.0,
            processedFrameCount: 150,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 75.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 150,
            completedOutputFrameCount: 150,
            completedOutputFrameRate: 75.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 150],
            outputCallbackLatencyHistogram: ["10.8ms": 120, "16.7ms": 30],
            minOutputCallbackLatencyMilliseconds: 10.8,
            maxOutputCallbackLatencyMilliseconds: 16.7,
            requestedMinimumFrameTime: 0,
            requestedQueueDepth: 2,
            requestedShowCursor: false,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            intervalCount: 149,
            minIntervalMilliseconds: 12.5,
            maxIntervalMilliseconds: 18.0,
            intervalHistogram: ["16.7ms": 149],
            stallCountOver16Milliseconds: 6,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "60hz-like",
            frameStatusHistogram: ["frame-complete": 150],
            notes: []
        )
        let bursty = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 154,
            completeFrameCount: 154,
            observedFrameRate: 77.0,
            processedFrameCount: 154,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 77.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 154,
            completedOutputFrameCount: 154,
            completedOutputFrameRate: 77.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 154],
            outputCallbackLatencyHistogram: ["10.8ms": 100, "33.3ms": 54],
            minOutputCallbackLatencyMilliseconds: 10.8,
            maxOutputCallbackLatencyMilliseconds: 33.3,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 4,
            requestedShowCursor: false,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            intervalCount: 153,
            minIntervalMilliseconds: 4.167,
            maxIntervalMilliseconds: 41.0,
            intervalHistogram: ["4.2ms": 70, "33.3ms": 83],
            stallCountOver16Milliseconds: 44,
            stallCountOver33Milliseconds: 8,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 154],
            notes: []
        )
        let evaluations = [
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "stable-hevc",
                    processingMode: .videoToolboxEncode,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "baseline-q2",
                        minimumFrameTime: 0,
                        queueDepth: 2,
                        showCursor: false
                    )
                ),
                result: stable,
                errorDescription: nil
            ),
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "bursty-hevc",
                    processingMode: .videoToolboxEncode,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "min-frame-240hz-q4",
                        minimumFrameTime: 1.0 / 240.0,
                        queueDepth: 4,
                        showCursor: false
                    )
                ),
                result: bursty,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations), 0)
    }

    func testProcessingMatrixRejectsLowOutputFrameRateCoalescedCandidate() {
        let coalescedSlow = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 170,
            completeFrameCount: 170,
            observedFrameRate: 85.0,
            processedFrameCount: 170,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 85.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 36,
            completedOutputFrameCount: 36,
            completedOutputFrameRate: 18.0,
            completedOutputFrameRatio: 36.0 / 170.0,
            outputCallbackStatusHistogram: ["noErr": 36],
            outputCallbackLatencyHistogram: ["18.0ms": 36],
            minOutputCallbackLatencyMilliseconds: 18.0,
            maxOutputCallbackLatencyMilliseconds: 18.0,
            requestedMinimumFrameTime: 1.0 / 120.0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            intervalCount: 169,
            minIntervalMilliseconds: 8.333,
            maxIntervalMilliseconds: 66.667,
            intervalHistogram: ["8.3ms": 90, "66.7ms": 79],
            stallCountOver16Milliseconds: 0,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "coalesced-or-mixed",
            frameStatusHistogram: ["frame-complete": 170],
            notes: []
        )
        let steadyNearRealtime = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 116,
            completeFrameCount: 116,
            observedFrameRate: 58.0,
            processedFrameCount: 116,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 58.0,
            processedFrameRatio: 1.0,
            outputCallbackCount: 116,
            completedOutputFrameCount: 116,
            completedOutputFrameRate: 58.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 116],
            outputCallbackLatencyHistogram: ["11.0ms": 116],
            minOutputCallbackLatencyMilliseconds: 11.0,
            maxOutputCallbackLatencyMilliseconds: 11.0,
            requestedMinimumFrameTime: 0,
            requestedQueueDepth: 2,
            requestedShowCursor: false,
            surfaceWidth: 3840,
            surfaceHeight: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            intervalCount: 115,
            minIntervalMilliseconds: 16.667,
            maxIntervalMilliseconds: 18.0,
            intervalHistogram: ["16.7ms": 115],
            stallCountOver16Milliseconds: 0,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "60hz-like",
            frameStatusHistogram: ["frame-complete": 116],
            notes: []
        )

        let evaluations = [
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "coalesced-slow",
                    processingMode: .videoToolboxEncode,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "legacy-120hz-request",
                        minimumFrameTime: 1.0 / 120.0,
                        queueDepth: 8,
                        showCursor: false
                    )
                ),
                result: coalescedSlow,
                errorDescription: nil
            ),
            MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
                candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                    identifier: "steady-near-realtime",
                    processingMode: .videoToolboxEncode,
                    tuningCandidate: MDKSkyLightDisplayStreamTuningCandidate(
                        identifier: "baseline-q2",
                        minimumFrameTime: 0,
                        queueDepth: 2,
                        showCursor: false
                    )
                ),
                result: steadyNearRealtime,
                errorDescription: nil
            )
        ]

        XCTAssertEqual(MDKSkyLightDisplayStreamProcessingMatrix.bestEvaluationIndex(for: evaluations), 1)
    }

    func testSkyLightAutotunerUsesLongerBenchmarkWindowForHighRefreshTargets() {
        XCTAssertEqual(
            MDKSkyLightDisplayStreamAutotuner.benchmarkSampleDuration(
                targetFrameRate: 120,
                displayRefreshRate: 120
            ),
            0.75
        )
        XCTAssertEqual(
            MDKSkyLightDisplayStreamAutotuner.benchmarkSampleDuration(
                targetFrameRate: 60,
                displayRefreshRate: 60
            ),
            0.35
        )
    }

    func testSkyLightAutotunerFallsBackToDeepBaselineCandidateWhenLiveResultsUnderrun() {
        let q2Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q2",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 18,
                completeFrameCount: 18,
                observedFrameRate: 24.0,
                processedFrameCount: 18,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 24.0,
                processedFrameRatio: 1.0,
                outputCallbackCount: 18,
                completedOutputFrameCount: 18,
                completedOutputFrameRate: 24.0,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 18],
                outputCallbackLatencyHistogram: ["18.0ms": 18],
                minOutputCallbackLatencyMilliseconds: 18.0,
                maxOutputCallbackLatencyMilliseconds: 18.0,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 2,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 17,
                minIntervalMilliseconds: 16.667,
                maxIntervalMilliseconds: 41.667,
                intervalHistogram: ["16.7ms": 9, "41.7ms": 8],
                stallCountOver16Milliseconds: 8,
                stallCountOver33Milliseconds: 8,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 18],
                notes: []
            ),
            errorDescription: nil
        )
        let q8Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q8",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue8Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 20,
                completeFrameCount: 20,
                observedFrameRate: 26.7,
                processedFrameCount: 20,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 26.7,
                processedFrameRatio: 1.0,
                outputCallbackCount: 20,
                completedOutputFrameCount: 20,
                completedOutputFrameRate: 26.7,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 20],
                outputCallbackLatencyHistogram: ["19.0ms": 20],
                minOutputCallbackLatencyMilliseconds: 19.0,
                maxOutputCallbackLatencyMilliseconds: 19.0,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 8,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 19,
                minIntervalMilliseconds: 16.667,
                maxIntervalMilliseconds: 41.667,
                intervalHistogram: ["16.7ms": 10, "41.7ms": 9],
                stallCountOver16Milliseconds: 9,
                stallCountOver33Milliseconds: 9,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 20],
                notes: []
            ),
            errorDescription: nil
        )

        XCTAssertEqual(
            MDKSkyLightDisplayStreamAutotuner.highRefreshGuardrailCandidate(
                for: [q2Evaluation, q8Evaluation],
                targetFrameRate: 120,
                displayRefreshRate: 120
            ),
            MDKSkyLightDisplayStreamTuningMatrix.baselineQueue8Candidate
        )
    }

    func testSkyLightAutotunerSkipsHighRefreshGuardrailWhenUsableCandidateExists() {
        let q2Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q2",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue2Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 50,
                completeFrameCount: 50,
                observedFrameRate: 66.07,
                processedFrameCount: 50,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 66.07,
                processedFrameRatio: 1.0,
                outputCallbackCount: 50,
                completedOutputFrameCount: 50,
                completedOutputFrameRate: 66.07,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 50],
                outputCallbackLatencyHistogram: ["54.4ms": 50],
                minOutputCallbackLatencyMilliseconds: 54.35,
                maxOutputCallbackLatencyMilliseconds: 54.35,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 2,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 49,
                minIntervalMilliseconds: 8.333,
                maxIntervalMilliseconds: 16.667,
                intervalHistogram: ["8.3ms": 17, "16.7ms": 32],
                stallCountOver16Milliseconds: 0,
                stallCountOver33Milliseconds: 0,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "120hz-like",
                frameStatusHistogram: ["frame-complete": 50],
                notes: []
            ),
            errorDescription: nil
        )
        let q8Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q8",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue8Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 24,
                completeFrameCount: 24,
                observedFrameRate: 32.07,
                processedFrameCount: 24,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 32.07,
                processedFrameRatio: 1.0,
                outputCallbackCount: 24,
                completedOutputFrameCount: 24,
                completedOutputFrameRate: 32.07,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 24],
                outputCallbackLatencyHistogram: ["42.3ms": 24],
                minOutputCallbackLatencyMilliseconds: 42.33,
                maxOutputCallbackLatencyMilliseconds: 42.33,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 8,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 23,
                minIntervalMilliseconds: 16.667,
                maxIntervalMilliseconds: 41.667,
                intervalHistogram: ["16.7ms": 8, "25.0ms": 8, "41.7ms": 7],
                stallCountOver16Milliseconds: 7,
                stallCountOver33Milliseconds: 7,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 24],
                notes: []
            ),
            errorDescription: nil
        )

        XCTAssertNil(
            MDKSkyLightDisplayStreamAutotuner.highRefreshGuardrailCandidate(
                for: [q2Evaluation, q8Evaluation],
                targetFrameRate: 120,
                displayRefreshRate: 120
            )
        )
    }

    func testSkyLightAutotunerSkipsHighRefreshGuardrailForHighThroughputMixedCadenceCandidate() {
        let q3Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q3",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue3Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 58,
                completeFrameCount: 58,
                observedFrameRate: 76.97,
                processedFrameCount: 58,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 76.97,
                processedFrameRatio: 1.0,
                outputCallbackCount: 58,
                completedOutputFrameCount: 58,
                completedOutputFrameRate: 76.97,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 58],
                outputCallbackLatencyHistogram: ["43.5ms": 58],
                minOutputCallbackLatencyMilliseconds: 43.49,
                maxOutputCallbackLatencyMilliseconds: 43.49,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 3,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 57,
                minIntervalMilliseconds: 8.333,
                maxIntervalMilliseconds: 33.333,
                intervalHistogram: ["8.3ms": 22, "16.7ms": 23, "25.0ms": 8, "33.3ms": 4],
                stallCountOver16Milliseconds: 12,
                stallCountOver33Milliseconds: 0,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 58],
                notes: []
            ),
            errorDescription: nil
        )
        let q8Evaluation = MDKSkyLightDisplayStreamProcessingMatrixEvaluation(
            candidate: MDKSkyLightDisplayStreamProcessingMatrixCandidate(
                identifier: "baseline-q8",
                processingMode: .videoToolboxEncode,
                tuningCandidate: MDKSkyLightDisplayStreamTuningMatrix.baselineQueue8Candidate
            ),
            result: MDKSkyLightDisplayStreamProcessingBenchmarkResult(
                displayID: 2,
                status: 0,
                stopStatus: 0,
                processingMode: .videoToolboxEncode,
                videoEncoderCodec: .hevc,
                sampleDuration: 0.75,
                callbackCount: 26,
                completeFrameCount: 26,
                observedFrameRate: 35.17,
                processedFrameCount: 26,
                processingFailureCount: 0,
                processingErrorHistogram: [:],
                processedFrameRate: 35.17,
                processedFrameRatio: 1.0,
                outputCallbackCount: 26,
                completedOutputFrameCount: 26,
                completedOutputFrameRate: 35.17,
                completedOutputFrameRatio: 1.0,
                outputCallbackStatusHistogram: ["noErr": 26],
                outputCallbackLatencyHistogram: ["44.0ms": 26],
                minOutputCallbackLatencyMilliseconds: 43.98,
                maxOutputCallbackLatencyMilliseconds: 43.98,
                requestedMinimumFrameTime: 0,
                requestedQueueDepth: 8,
                requestedShowCursor: false,
                surfaceWidth: 3840,
                surfaceHeight: 2160,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                intervalCount: 25,
                minIntervalMilliseconds: 16.667,
                maxIntervalMilliseconds: 41.667,
                intervalHistogram: ["16.7ms": 9, "25.0ms": 8, "41.7ms": 8],
                stallCountOver16Milliseconds: 8,
                stallCountOver33Milliseconds: 8,
                stallCountOver100Milliseconds: 0,
                cadenceClassification: "coalesced-or-mixed",
                frameStatusHistogram: ["frame-complete": 26],
                notes: []
            ),
            errorDescription: nil
        )

        XCTAssertNil(
            MDKSkyLightDisplayStreamAutotuner.highRefreshGuardrailCandidate(
                for: [q3Evaluation, q8Evaluation],
                targetFrameRate: 120,
                displayRefreshRate: 120
            )
        )
    }

    func testSkyLightDisplayStreamProcessingBenchmarkMarks120LikeTarget() {
        let result = MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: 2,
            status: 0,
            stopStatus: 0,
            processingMode: .videoToolboxEncode,
            videoEncoderCodec: .hevc,
            sampleDuration: 2.0,
            callbackCount: 220,
            completeFrameCount: 220,
            observedFrameRate: 110.0,
            processedFrameCount: 218,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            processedFrameRate: 109.0,
            processedFrameRatio: 0.99,
            outputCallbackCount: 112,
            completedOutputFrameCount: 218,
            completedOutputFrameRate: 109.0,
            completedOutputFrameRatio: 1.0,
            outputCallbackStatusHistogram: ["noErr": 220],
            outputCallbackLatencyHistogram: ["0.8ms": 218, "1.0ms": 2],
            minOutputCallbackLatencyMilliseconds: 0.8,
            maxOutputCallbackLatencyMilliseconds: 1.0,
            requestedMinimumFrameTime: 1.0 / 240.0,
            requestedQueueDepth: 8,
            requestedShowCursor: false,
            surfaceWidth: 5120,
            surfaceHeight: 2880,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            intervalCount: 219,
            minIntervalMilliseconds: 4.166,
            maxIntervalMilliseconds: 8.333,
            intervalHistogram: ["4.2ms": 160, "8.3ms": 59],
            stallCountOver16Milliseconds: 0,
            stallCountOver33Milliseconds: 0,
            stallCountOver100Milliseconds: 0,
            cadenceClassification: "120hz-like",
            frameStatusHistogram: ["frame-complete": 220],
            notes: []
        )

        XCTAssertTrue(result.meets120LikeTarget)
    }

    func testScreenCaptureKitProxyHandshakeTraceRoundTripsThroughJSON() throws {
        let trace = MDKScreenCaptureKitProxyHandshakeTrace(
            displayID: 42,
            sampleDuration: 1.5,
            status: 0,
            succeeded: true,
            streamID: "stream-123",
            filterID: "filter-456",
            selectors: [
                "fetchDisplay:withCompletionHandler:",
                "proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:"
            ],
            symbols: [
                "SLSDisplayStreamCreateProxying"
            ],
            steps: [
                MDKScreenCaptureKitProxyHandshakeStep(
                    name: "fetch-display",
                    selector: "fetchDisplay:withCompletionHandler:",
                    symbol: nil,
                    status: 0,
                    succeeded: true,
                    notes: ["Resolved target display."]
                ),
                MDKScreenCaptureKitProxyHandshakeStep(
                    name: "proxy-core-graphics",
                    selector: "proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:",
                    symbol: "SLSDisplayStreamCreateProxying",
                    status: 0,
                    succeeded: true,
                    notes: ["Forwarded proxy request to the daemon."]
                )
            ],
            notes: [
                "Trace completed successfully."
            ]
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(MDKScreenCaptureKitProxyHandshakeTrace.self, from: data)
        XCTAssertEqual(decoded, trace)
    }

    func testScreenCaptureKitProxyHandshakeTraceParsesShimDictionary() throws {
        let payload: NSDictionary = [
            "displayID": NSNumber(value: 77),
            "sampleDuration": NSNumber(value: 2.0),
            "status": NSNumber(value: 0),
            "succeeded": NSNumber(value: true),
            "streamID": "stream-77",
            "filterID": "filter-77",
            "selectors": [
                "fetchDisplay:withCompletionHandler:",
                "startCapture:withContentFilter:preservedFilter:transactionID:properties:extensionToken:completionHandler:",
                "proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:"
            ],
            "symbols": [
                "SLSDisplayStreamCreateProxying",
                "SLSHWCaptureStreamCreateProxying"
            ],
            "steps": [
                [
                    "name": "fetch-display",
                    "selector": "fetchDisplay:withCompletionHandler:",
                    "status": NSNumber(value: 0),
                    "succeeded": NSNumber(value: true),
                    "notes": ["Display lookup completed."]
                ],
                [
                    "name": "proxy-core-graphics",
                    "selector": "proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:",
                    "symbol": "SLSDisplayStreamCreateProxying",
                    "status": NSNumber(value: 0),
                    "succeeded": NSNumber(value: true),
                    "notes": ["Proxy stream creation returned success."]
                ],
                [
                    "name": "delivery-comparison",
                    "selector": "stream:didOutputSampleBuffer:ofType:",
                    "status": NSNumber(value: 0),
                    "succeeded": NSNumber(value: true),
                    "notes": [
                        "firstPublicSamplePrecedingEventKind=post-start-stream-state",
                        "firstPublicSamplePrecedingEventLeadMilliseconds=1.25",
                        "firstPublicSampleLastVideoEventKind=stream-post-start-remote-video-state",
                        "firstPublicSampleInterveningEventKinds=[\"stream-start-remote-audio-receive-queue\",\"stream-start-remote-microphone-receive-queue\"]",
                        "videoQueueWrapperOriginalInvokeSymbol=__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke",
                        "videoQueueWrapperOriginalInvokeImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                        "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                        "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit",
                        "lastCollectStreamDataExitLeadMilliseconds=<null>"
                    ]
                ]
            ],
            "notes": [
                "Handshake trace payload parsed.",
                "firstPublicSamplePrecedingEventKind=post-start-stream-state",
                "firstPublicSamplePrecedingEventLeadMilliseconds=1.25",
                "firstPublicSampleLastVideoEventKind=stream-post-start-remote-video-state",
                "firstPublicSampleInterveningEventKinds=[\"stream-start-remote-audio-receive-queue\",\"stream-start-remote-microphone-receive-queue\"]",
                "videoQueueWrapperOriginalInvokeSymbol=__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke",
                "videoQueueWrapperOriginalInvokeImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit",
                "lastCollectStreamDataExitLeadMilliseconds=<null>",
                "sampleBufferArrivalDelta120HzEquivalentCount=35",
                "sampleBufferArrivalCadenceClassification=coalesced-or-mixed",
                "sampleBufferPresentationDelta120HzEquivalentCount=31",
                "sampleBufferPresentationCadenceClassification=coalesced-or-mixed"
            ]
        ]

        let trace = try MDKScreenCaptureKitProxyHandshakeTrace(shimDictionary: payload)
        XCTAssertEqual(trace.displayID, 77)
        XCTAssertEqual(trace.sampleDuration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(trace.status, 0)
        XCTAssertTrue(trace.succeeded)
        XCTAssertEqual(trace.streamID, "stream-77")
        XCTAssertEqual(trace.filterID, "filter-77")
        XCTAssertEqual(
            trace.selectors,
            [
                "fetchDisplay:withCompletionHandler:",
                "startCapture:withContentFilter:preservedFilter:transactionID:properties:extensionToken:completionHandler:",
                "proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:"
            ]
        )
        XCTAssertEqual(
            trace.symbols,
            [
                "SLSDisplayStreamCreateProxying",
                "SLSHWCaptureStreamCreateProxying"
            ]
        )
        XCTAssertEqual(trace.steps.count, 3)
        XCTAssertEqual(trace.steps[0].name, "fetch-display")
        XCTAssertEqual(trace.steps[0].selector, "fetchDisplay:withCompletionHandler:")
        XCTAssertEqual(trace.steps[0].status, 0)
        XCTAssertEqual(trace.steps[0].succeeded, true)
        XCTAssertEqual(trace.steps[1].symbol, "SLSDisplayStreamCreateProxying")
        XCTAssertEqual(trace.steps[2].name, "delivery-comparison")
        XCTAssertEqual(trace.steps[2].selector, "stream:didOutputSampleBuffer:ofType:")
        XCTAssertTrue(trace.steps[2].notes.contains("firstPublicSamplePrecedingEventKind=post-start-stream-state"))
        XCTAssertTrue(trace.steps[2].notes.contains("firstPublicSamplePrecedingEventLeadMilliseconds=1.25"))
        XCTAssertTrue(trace.steps[2].notes.contains("firstPublicSampleLastVideoEventKind=stream-post-start-remote-video-state"))
        XCTAssertTrue(trace.steps[2].notes.contains("firstPublicSampleInterveningEventKinds=[\"stream-start-remote-audio-receive-queue\",\"stream-start-remote-microphone-receive-queue\"]"))
        XCTAssertTrue(trace.steps[2].notes.contains("videoQueueWrapperOriginalInvokeSymbol=__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke"))
        XCTAssertTrue(trace.steps[2].notes.contains("videoQueueWrapperOriginalInvokeImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia"))
        XCTAssertTrue(trace.steps[2].notes.contains("videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia"))
        XCTAssertTrue(trace.steps[2].notes.contains("videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit"))
        XCTAssertTrue(trace.steps[2].notes.contains("lastCollectStreamDataExitLeadMilliseconds=<null>"))
        XCTAssertEqual(
            trace.notes,
            [
                "Handshake trace payload parsed.",
                "firstPublicSamplePrecedingEventKind=post-start-stream-state",
                "firstPublicSamplePrecedingEventLeadMilliseconds=1.25",
                "firstPublicSampleLastVideoEventKind=stream-post-start-remote-video-state",
                "firstPublicSampleInterveningEventKinds=[\"stream-start-remote-audio-receive-queue\",\"stream-start-remote-microphone-receive-queue\"]",
                "videoQueueWrapperOriginalInvokeSymbol=__FigRemoteOperationReceiverCreateMessageReceiver_block_invoke",
                "videoQueueWrapperOriginalInvokeImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                "videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit",
                "lastCollectStreamDataExitLeadMilliseconds=<null>",
                "sampleBufferArrivalDelta120HzEquivalentCount=35",
                "sampleBufferArrivalCadenceClassification=coalesced-or-mixed",
                "sampleBufferPresentationDelta120HzEquivalentCount=31",
                "sampleBufferPresentationCadenceClassification=coalesced-or-mixed"
            ]
        )
    }

    func testScreenCaptureKitRuntimeInventoryRoundTripsThroughJSON() throws {
        let inventory = MDKScreenCaptureKitRuntimeInventory(
            classes: [
                MDKScreenCaptureKitRuntimeClassInventory(
                    className: "SCStream",
                    loaded: true,
                    filteredMethods: ["startCaptureWithCompletionHandler:", "startRemoteVideoReceiveQueue:"],
                    filteredMethodCount: 2
                )
            ],
            screenCaptureKitSymbols: [
                "SCRemoteQueue_CreateReceiverQueue": true,
                "SCRemoteQueue_UpdateReceiverQueue": true,
            ],
            cmCaptureSymbols: [
                "FigRemoteQueueReceiverCreateFromXPCObject": true,
                "FigRemoteQueueReceiverDrain": false,
            ],
            notes: ["runtime inventory parsed"]
        )

        let data = try JSONEncoder().encode(inventory)
        let decoded = try JSONDecoder().decode(MDKScreenCaptureKitRuntimeInventory.self, from: data)
        XCTAssertEqual(decoded, inventory)
    }

    func testScreenCaptureKitRuntimeInventoryParsesShimDictionary() throws {
        let payload: NSDictionary = [
            "classes": [
                [
                    "className": "SCStreamManager",
                    "loaded": NSNumber(value: true),
                    "filteredMethods": [
                        "startRemoteQueue:streamID:",
                        "stopRemoteQueue:streamID:"
                    ],
                    "filteredMethodCount": NSNumber(value: 2)
                ]
            ],
            "screenCaptureKitSymbols": [
                "SCRemoteQueue_CreateReceiverQueue": NSNumber(value: true),
                "SCRemoteQueue_Drain": NSNumber(value: false)
            ],
            "cmCaptureSymbols": [
                "FigRemoteQueueReceiverCreateFromXPCObject": NSNumber(value: true),
                "FigRemoteQueueReceiverDrain": NSNumber(value: false)
            ],
            "notes": [
                "inventory payload parsed"
            ]
        ]

        let inventory = try MDKScreenCaptureKitRuntimeInventory(shimDictionary: payload)
        XCTAssertEqual(inventory.classes.count, 1)
        XCTAssertEqual(inventory.classes.first?.className, "SCStreamManager")
        XCTAssertEqual(inventory.classes.first?.filteredMethodCount, 2)
        XCTAssertEqual(inventory.screenCaptureKitSymbols["SCRemoteQueue_CreateReceiverQueue"], true)
        XCTAssertEqual(inventory.screenCaptureKitSymbols["SCRemoteQueue_Drain"], false)
        XCTAssertEqual(inventory.cmCaptureSymbols["FigRemoteQueueReceiverCreateFromXPCObject"], true)
        XCTAssertEqual(inventory.cmCaptureSymbols["FigRemoteQueueReceiverDrain"], false)
        XCTAssertEqual(inventory.notes, ["inventory payload parsed"])
    }

    func testPrivateCapturePrototypePlannerPrefersProxyingPathWhenAvailable() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: true,
                displayIOSurfaceCaptureWithOptionsAvailable: true,
                displayIOSurfaceProxyCaptureAvailable: true,
                displayStreamProxyAvailable: false,
                extendedRangeOptionAvailable: true
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .displayIOSurfaceProxying)
        XCTAssertTrue(plan.readyForIOSurfacePrototype)
    }

    func testPrivateCapturePrototypePlannerPrefersDisplayStreamProxyWhenAvailable() {
        let plan = MDKPrivateCapturePrototypePlanner.plan(
            for: MDKPrivateCaptureCapabilities(
                desktopCaptureAvailable: true,
                displayIOSurfaceCaptureAvailable: true,
                displayIOSurfaceCaptureWithOptionsAvailable: true,
                displayIOSurfaceProxyCaptureAvailable: true,
                displayStreamProxyAvailable: true,
                extendedRangeOptionAvailable: true
            )
        )

        XCTAssertEqual(plan.recommendedEntryPoint, .displayStreamProxying)
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

    func testReplaydProducerSampleParserDetectsProducerAndSkyLightIndicators() throws {
        let sampleText = """
        1 Thread_1838321   DispatchQueue_14903: com.apple.coremedia.remotequeue_sender.readqueue  (serial)
          1 rqSenderHandleDequeue  (in CMCapture) + 64  [0x1a71102c0]
        _SCRemoteQueue_Enqueue
        _FigRemoteQueueSenderEnqueue
        _FigRemoteQueueSenderResetIfFullAndEnqueue
        _FigRemoteQueueSenderCreate
        _FigRemoteQueueSenderCreateXPCObject
        _FigRemoteQueueSenderSetMaximumBufferAge
        -[RPClientProxy startRemoteQueue:streamID:]
        -[RPClientProxy captureHandlerWithSample:timingData:]
        +                     ! 4 CGYDisplayStreamNotification_server  (in SkyLight) + 476  [0x189ef8414]
        +                     !   2 _CGYDisplayStreamFrameAvailable  (in SkyLight) + 1288  [0x189c51168]
        +                     !   : 2 __65-[SLContentStream initWithFilter:properties:queue:handler:error:]_block_invoke.375  (in SkyLight) + 208  [0x189aca2ac]
        """

        let report = MDKReplaydProducerSampleParser.analyze(
            sampleText: sampleText,
            replaydPID: 740,
            sampleDuration: 1.0,
            sampleIntervalMilliseconds: 1
        )

        XCTAssertEqual(report.replaydPID, 740)
        XCTAssertTrue(report.observedProducerReadQueue)
        XCTAssertTrue(report.observedRQSenderHandleDequeue)
        XCTAssertTrue(report.observedFigRemoteQueueSenderSetup)
        XCTAssertTrue(report.observedRPClientProxyCaptureHandler)
        XCTAssertTrue(report.observedRPClientProxyStartRemoteQueue)
        XCTAssertTrue(report.observedSkyLightDisplayStreamFrameAvailable)
        XCTAssertTrue(report.observedSLContentStream)
        XCTAssertFalse(report.indicators.isEmpty)
        XCTAssertEqual(report.indicators.first(where: { $0.name == "sc-remote-queue-enqueue" })?.matchCount, 1)
        XCTAssertEqual(report.indicators.first(where: { $0.name == "fig-remote-queue-sender-enqueue" })?.matchCount, 1)
        XCTAssertEqual(report.indicators.first(where: { $0.name == "fig-remote-queue-sender-reset" })?.matchCount, 1)
        XCTAssertEqual(report.indicators.first(where: { $0.name == "fig-remote-queue-sender-max-buffer-age" })?.matchCount, 1)
    }

    func testReplaydProducerSampleReportRoundTripsThroughJSON() throws {
        let report = MDKReplaydProducerSampleReport(
            replaydPID: 740,
            sampleDuration: 1.0,
            sampleIntervalMilliseconds: 1,
            totalLineCount: 10,
            observedProducerReadQueue: true,
            observedRQSenderHandleDequeue: true,
            observedFigRemoteQueueSenderSetup: true,
            observedRPClientProxyCaptureHandler: false,
            observedRPClientProxyStartRemoteQueue: true,
            observedSkyLightDisplayStreamFrameAvailable: true,
            observedSLContentStream: true,
            indicators: [
                MDKReplaydProducerSampleIndicator(
                    name: "producer-read-queue",
                    pattern: "rqSenderHandleDequeue",
                    matchCount: 1,
                    matchedLines: ["rqSenderHandleDequeue  (in CMCapture) + 64  [0x1a71102c0]"]
                )
            ]
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(MDKReplaydProducerSampleReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testReplaydProducerSampleComparatorSeparatesPersistentAndDivergentIndicators() {
        let baseline = MDKReplaydProducerSampleReport(
            replaydPID: 740,
            sampleDuration: 1.0,
            sampleIntervalMilliseconds: 1,
            totalLineCount: 4,
            observedProducerReadQueue: true,
            observedRQSenderHandleDequeue: true,
            observedFigRemoteQueueSenderSetup: false,
            observedRPClientProxyCaptureHandler: false,
            observedRPClientProxyStartRemoteQueue: false,
            observedSkyLightDisplayStreamFrameAvailable: true,
            observedSLContentStream: true,
            indicators: [
                MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchCount: 3, matchedLines: ["rqSenderHandleDequeue"]),
                MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchCount: 2, matchedLines: ["CGYDisplayStreamNotification_server"]),
                MDKReplaydProducerSampleIndicator(name: "slcontentstream", pattern: "SLContentStream", matchCount: 1, matchedLines: ["SLContentStream"])
            ]
        )
        let stimulus = MDKReplaydProducerSampleReport(
            replaydPID: 740,
            sampleDuration: 1.0,
            sampleIntervalMilliseconds: 1,
            totalLineCount: 3,
            observedProducerReadQueue: false,
            observedRQSenderHandleDequeue: false,
            observedFigRemoteQueueSenderSetup: false,
            observedRPClientProxyCaptureHandler: false,
            observedRPClientProxyStartRemoteQueue: false,
            observedSkyLightDisplayStreamFrameAvailable: true,
            observedSLContentStream: true,
            indicators: [
                MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchCount: 0, matchedLines: []),
                MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchCount: 4, matchedLines: ["CGYDisplayStreamNotification_server"]),
                MDKReplaydProducerSampleIndicator(name: "slcontentstream", pattern: "SLContentStream", matchCount: 2, matchedLines: ["SLContentStream"])
            ]
        )

        let comparison = MDKReplaydProducerSampleComparator.compare(
            baseline: baseline,
            stimulus: stimulus
        )

        XCTAssertEqual(comparison.persistentIndicatorNames, ["skylight-display-stream", "slcontentstream"])
        XCTAssertEqual(comparison.baselineOnlyIndicatorNames, ["producer-read-queue"])
        XCTAssertEqual(comparison.stimulusOnlyIndicatorNames, [])
        XCTAssertEqual(comparison.indicatorComparisons.count, 3)
        XCTAssertEqual(comparison.indicatorComparisons[0].baselineMatchCount, 3)
        XCTAssertEqual(comparison.indicatorComparisons[0].stimulusMatchCount, 0)
    }

    func testReplaydProducerSampleSeriesAnalyzerSummarizesWindowCounts() {
        let reports = [
            MDKReplaydProducerSampleReport(
                replaydPID: 740,
                sampleDuration: 1.0,
                sampleIntervalMilliseconds: 1,
                totalLineCount: 3,
                observedProducerReadQueue: true,
                observedRQSenderHandleDequeue: true,
                observedFigRemoteQueueSenderSetup: false,
                observedRPClientProxyCaptureHandler: false,
                observedRPClientProxyStartRemoteQueue: false,
                observedSkyLightDisplayStreamFrameAvailable: true,
                observedSLContentStream: true,
                indicators: [
                    MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchCount: 2, matchedLines: ["rqSenderHandleDequeue"]),
                    MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchCount: 1, matchedLines: ["CGYDisplayStreamNotification_server"])
                ]
            ),
            MDKReplaydProducerSampleReport(
                replaydPID: 740,
                sampleDuration: 1.0,
                sampleIntervalMilliseconds: 1,
                totalLineCount: 2,
                observedProducerReadQueue: false,
                observedRQSenderHandleDequeue: false,
                observedFigRemoteQueueSenderSetup: false,
                observedRPClientProxyCaptureHandler: false,
                observedRPClientProxyStartRemoteQueue: false,
                observedSkyLightDisplayStreamFrameAvailable: true,
                observedSLContentStream: true,
                indicators: [
                    MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchCount: 0, matchedLines: []),
                    MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchCount: 3, matchedLines: ["CGYDisplayStreamNotification_server"])
                ]
            )
        ]

        let summary = MDKReplaydProducerSampleSeriesAnalyzer.summarize(reports: reports)

        XCTAssertEqual(summary.windowCount, 2)
        XCTAssertEqual(summary.indicatorSummaries.count, 2)
        XCTAssertEqual(summary.indicatorSummaries[0].name, "producer-read-queue")
        XCTAssertEqual(summary.indicatorSummaries[0].windowMatchCounts, [2, 0])
        XCTAssertEqual(summary.indicatorSummaries[0].totalMatchCount, 2)
        XCTAssertEqual(summary.indicatorSummaries[0].peakMatchCount, 2)
        XCTAssertEqual(summary.indicatorSummaries[0].nonzeroWindowCount, 1)
    }

    func testReplaydXctraceArtifactParserCountsExportRows() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-query-result>
          <node xpath='//trace-toc[1]/run[1]/data[1]/table[2]'>
            <schema name="syscall"/>
            <row>
              <sample-time id="1">1</sample-time>
              <syscall fmt="write"/>
              <backtrace>
                <frame name="FigRemoteQueueSenderResetIfFullAndEnqueueSequence"/>
                <frame name="roEnqueueSampleBuffer"/>
              </backtrace>
              <formatted-label fmt="write (fd: 15 , buf: 0x1 , len: 2 Bytes ) = 2 Bytes"/>
            </row>
            <row>
              <sample-time id="2">8333334</sample-time>
              <syscall fmt="write"/>
              <backtrace>
                <frame name="roEnqueueSampleBuffer"/>
              </backtrace>
              <formatted-label fmt="write (fd: 15 , buf: 0x2 , len: 2 Bytes ) = 2 Bytes"/>
            </row>
            <row>
              <sample-time id="3">16666667</sample-time>
              <syscall fmt="write"/>
              <backtrace>
                <frame name="roEnqueueSampleBuffer"/>
              </backtrace>
              <formatted-label fmt="write (fd: 15 , buf: 0x3 , len: 2 Bytes ) = 2 Bytes"/>
            </row>
            <row>
              <sample-time id="4">25000001</sample-time>
              <syscall fmt="kevent_id"/>
              <backtrace>
                <frame name="rqSenderHandleDequeue"/>
                <frame name="SLContentStream"/>
              </backtrace>
              <formatted-label fmt="kevent_id"/>
            </row>
          </node>
        </trace-query-result>
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "syscall",
            outputPath: "/tmp/syscall.xml",
            exportText: xml
        )

        XCTAssertEqual(summary.schema, "syscall")
        XCTAssertEqual(summary.outputPath, "/tmp/syscall.xml")
        XCTAssertEqual(summary.rowCount, 4)
        XCTAssertTrue(summary.containsRows)
        XCTAssertEqual(summary.hotSymbolHistogram["FigRemoteQueueSenderResetIfFullAndEnqueueSequence"], 1)
        XCTAssertEqual(summary.hotSymbolHistogram["roEnqueueSampleBuffer"], 3)
        XCTAssertEqual(summary.hotSymbolHistogram["rqSenderHandleDequeue"], 1)
        XCTAssertEqual(summary.hotSymbolHistogram["SLContentStream"], 1)
        let sampleBufferCadence = try XCTUnwrap(
            summary.hotSymbolCadenceSummaries.first(where: { $0.symbolName == "roEnqueueSampleBuffer" })
        )
        XCTAssertEqual(sampleBufferCadence.eventCount, 3)
        XCTAssertEqual(sampleBufferCadence.cadenceClassification, "120hz-like")
        let sampleBufferSyscalls = try XCTUnwrap(
            summary.hotSymbolSyscallSummaries.first(where: { $0.symbolName == "roEnqueueSampleBuffer" })
        )
        XCTAssertEqual(sampleBufferSyscalls.syscallHistogram["write"], 3)
        XCTAssertEqual(sampleBufferSyscalls.signatureExamples.count, 3)
        let sampleBufferWriteCadence = try XCTUnwrap(
            summary.hotSymbolSyscallCadenceSummaries.first(
                where: { $0.symbolName == "roEnqueueSampleBuffer" && $0.syscallName == "write" }
            )
        )
        XCTAssertEqual(sampleBufferWriteCadence.eventCount, 3)
        XCTAssertEqual(sampleBufferWriteCadence.cadenceClassification, "120hz-like")
        XCTAssertFalse(summary.excerpt.isEmpty)
    }

    func testReplaydXctraceArtifactParserSummarizesReplaydContextSwitchThreads() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-query-result>
          <node xpath='//trace-toc[1]/run[1]/data[1]/table[11]'>
            <schema name="context-switch"/>
            <row>
              <event-time id="1" fmt="00:00.000.000">0</event-time>
              <thread id="11" fmt="replayd (0x21d1e0) (replayd, pid: 1740)"><tid id="12" fmt="0x21d1e0">2216416</tid><process id="13" fmt="replayd (1740)"><pid id="14" fmt="1740">1740</pid></process></thread>
              <sched-event id="16" fmt="Running">Running</sched-event>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="2" fmt="00:00.016.667">16667000</event-time>
              <thread ref="11"/>
              <sched-event ref="16"/>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="3" fmt="00:00.033.334">33334000</event-time>
              <thread ref="11"/>
              <sched-event ref="16"/>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="4" fmt="00:00.000.000">0</event-time>
              <thread id="21" fmt="replayd (0x21d3bd) (replayd, pid: 1740)"><tid id="22" fmt="0x21d3bd">2216893</tid><process ref="13"/></thread>
              <sched-event ref="16"/>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="5" fmt="00:00.016.900">16900000</event-time>
              <thread ref="21"/>
              <sched-event ref="16"/>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="6" fmt="00:00.033.800">33800000</event-time>
              <thread ref="21"/>
              <sched-event ref="16"/>
              <process ref="13"/>
            </row>
            <row>
              <event-time id="7" fmt="00:00.000.000">0</event-time>
              <thread id="31" fmt="Main Thread (0x10e8) (WindowServer, pid: 5408)">
                <tid id="32" fmt="0x10e8">4328</tid>
                <process id="33" fmt="WindowServer (5408)"><pid id="34" fmt="5408">5408</pid></process>
              </thread>
              <sched-event ref="16"/>
              <process ref="33"/>
            </row>
            <row>
              <event-time id="8" fmt="00:00.016.750">16750000</event-time>
              <thread ref="31"/>
              <sched-event ref="16"/>
              <process ref="33"/>
            </row>
            <row>
              <event-time id="9" fmt="00:00.033.500">33500000</event-time>
              <thread ref="31"/>
              <sched-event ref="16"/>
              <process ref="33"/>
            </row>
          </node>
        </trace-query-result>
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "context-switch",
            outputPath: "/tmp/context-switch.xml",
            exportText: xml
        )

        XCTAssertEqual(summary.schema, "context-switch")
        XCTAssertEqual(summary.rowCount, 9)
        XCTAssertEqual(summary.replaydRunningThreadCadenceSummaries.count, 2)
        let firstThread = try XCTUnwrap(
            summary.replaydRunningThreadCadenceSummaries.first(where: { $0.threadID == "2216416" })
        )
        XCTAssertEqual(firstThread.eventName, "Running")
        XCTAssertEqual(firstThread.eventCount, 3)
        XCTAssertEqual(firstThread.cadenceClassification, "60hz-like")
        let secondThread = try XCTUnwrap(
            summary.replaydRunningThreadCadenceSummaries.first(where: { $0.threadID == "2216893" })
        )
        XCTAssertEqual(secondThread.eventCount, 3)
        XCTAssertEqual(secondThread.cadenceClassification, "60hz-like")
        let windowServerMainThread = try XCTUnwrap(
            summary.windowServerRunningThreadCadenceSummaries.first(where: { $0.threadID == "4328" })
        )
        XCTAssertEqual(windowServerMainThread.eventCount, 3)
        XCTAssertEqual(windowServerMainThread.cadenceClassification, "60hz-like")
    }

    func testReplaydXctraceArtifactParserMatchesWindowServerDisplayStreamHotSymbolsFromSyscallRows() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-query-result>
          <node xpath='//trace-toc[1]/run[1]/data[1]/table[2]'>
            <schema name="syscall"/>
            <row>
              <start-time id="1" fmt="00:00.555.134">555134333</start-time>
              <thread id="2" fmt="Main Thread (0x10e8) (WindowServer, pid: 5408)">
                <tid id="3" fmt="0x10e8">4328</tid>
                <process id="4" fmt="WindowServer (5408)"><pid id="5" fmt="5408">5408</pid></process>
              </thread>
              <syscall id="6" fmt="mach_msg2_trap">MSC_mach_msg2_trap</syscall>
              <formatted-label id="7" fmt="mach_msg2_trap"/>
              <tagged-backtrace id="8" fmt="mach_msg2_trap ← (13 other frames)">
                <backtrace id="9">
                  <frame id="10" name="_cgy_DisplayStreamFrameAvailable" addr="0x189ef819c"/>
                  <frame id="11" name="displaystream_send_flags(CGXDisplayStream*, unsigned long long, unsigned int)" addr="0x189bd2430"/>
                  <frame id="12" name="displaystream_update(CGXDisplayStream*, std::__1::shared_ptr&lt;WS::Displays::Display&gt;, double)" addr="0x189bd11c0"/>
                  <frame id="13" name="displaystream_update_timer_callback(void*, double)" addr="0x189bd2570"/>
                  <frame id="14" name="CGXRunOneServicesPass" addr="0x189b65c54"/>
                </backtrace>
              </tagged-backtrace>
            </row>
          </node>
        </trace-query-result>
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "syscall",
            outputPath: "/tmp/windowserver-syscall.xml",
            exportText: xml
        )

        XCTAssertEqual(summary.hotSymbolHistogram["CGYDisplayStreamFrameAvailable"], 1)
        XCTAssertEqual(summary.hotSymbolHistogram["displaystream_update"], 3)
        XCTAssertEqual(summary.hotSymbolHistogram["CGXRunOneServicesPass"], 1)
    }

    func testReplaydXctraceArtifactParserSummarizesReplaydRunnableSourcesFromThreadState() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-query-result>
          <node xpath='//trace-toc[1]/run[1]/data[1]/table[12]'>
            <schema name="thread-state"/>
            <row>
              <start-time id="1" fmt="00:00.437.268">437268541</start-time>
              <thread id="11" fmt="replayd (0x22a025) (replayd, pid: 1740)">
                <tid id="12" fmt="0x22a025">2269221</tid>
                <process id="13" fmt="replayd (1740)"><pid id="14" fmt="1740">1740</pid></process>
              </thread>
              <thread-state id="15" fmt="Runnable">Runnable</thread-state>
              <narrative id="16" fmt="made runnable by  Main Thread (0x10e8) (WindowServer, pid: 5408)  running on  CPU 7 (P Core)"/>
              <narrative id="17" fmt="Runnable  at priority  37"/>
            </row>
            <row>
              <start-time id="2" fmt="00:00.472.859">472859208</start-time>
              <thread id="21" fmt="replayd (0x22a165) (replayd, pid: 1740)">
                <tid id="22" fmt="0x22a165">2269541</tid>
                <process ref="13"/>
              </thread>
              <thread-state ref="15"/>
              <process ref="13"/>
              <narrative id="23" fmt="made runnable by  replayd (0x22a025) (replayd, pid: 1740)  running on  CPU 9 (P Core)"/>
              <narrative ref="17"/>
            </row>
            <row>
              <start-time id="3" fmt="00:00.489.740">489740333</start-time>
              <thread id="31" fmt="replayd (0x22a165) (replayd, pid: 1740)">
                <tid id="32" fmt="0x22a165">2269541</tid>
                <process ref="13"/>
              </thread>
              <thread-state ref="15"/>
              <process ref="13"/>
              <narrative id="24" fmt="made runnable by  replayd (0x22a025) (replayd, pid: 1740)  running on  CPU 0 (E Core)"/>
              <narrative ref="17"/>
            </row>
          </node>
        </trace-query-result>
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeTableArtifact(
            schema: "thread-state",
            outputPath: "/tmp/thread-state.xml",
            exportText: xml
        )

        XCTAssertEqual(summary.schema, "thread-state")
        XCTAssertEqual(summary.rowCount, 3)
        XCTAssertFalse(summary.replaydRunnableSourceSummaries.isEmpty)
        let flattenedSources = summary.replaydRunnableSourceSummaries.flatMap(\.runnableSourceHistogram.keys)
        XCTAssertTrue(
            flattenedSources.contains("made runnable by  Main Thread (0x10e8) (WindowServer, pid: 5408)  running on  CPU 7 (P Core)")
        )
    }

    func testReplaydUnifiedLogArtifactParserFiltersInterestingLines() {
        let logText = """
        {"timestamp":"2026-03-21T16:27:18.000+09:00","eventMessage":"noise"}
        {"timestamp":"2026-03-21T16:27:18.041+09:00","eventMessage":"-[SCCaptureSession setupHealthMonitor]_block_invoke:1174 Health: captureSession=0xa538b4000"}
        {"timestamp":"2026-03-21T16:27:18.050+09:00","eventMessage":"-[RPClient hasScreenCaptureAccessWithAuditToken:fetchCurrentProcess:currentProcessShareableContentFilter:contentPickerFilter:error:]:2031 TCC Allow"}
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeUnifiedLogArtifact(
            outputPath: "/tmp/replayd-log.ndjson",
            logText: logText
        )

        XCTAssertEqual(summary.outputPath, "/tmp/replayd-log.ndjson")
        XCTAssertEqual(summary.lineCount, 3)
        XCTAssertEqual(summary.matchedLineCount, 2)
        XCTAssertEqual(summary.matchedLines.count, 2)
    }

    func testReplaydUnifiedLogArtifactParserSummarizesEnqueueFailures() throws {
        let logText = """
        {"threadID":2068394,"senderProgramCounter":766532,"backtrace":{"frames":[{"imageOffset":766532}]},"timestamp":"2026-03-21 16:33:24.595233+0900","eventMessage":" [ERROR] _SCRemoteQueue_Enqueue:217 remoteQueue=0xa542ef6c0 err=-19641 opType=3 Error occurred when enqueuing data"}
        {"threadID":2069384,"senderProgramCounter":766532,"backtrace":{"frames":[{"imageOffset":766532}]},"timestamp":"2026-03-21 16:33:24.612081+0900","eventMessage":" [ERROR] _SCRemoteQueue_Enqueue:217 remoteQueue=0xa542ef6c0 err=-19641 opType=3 Error occurred when enqueuing data"}
        {"threadID":2068394,"senderProgramCounter":766532,"backtrace":{"frames":[{"imageOffset":766532}]},"timestamp":"2026-03-21 16:33:24.632011+0900","eventMessage":" [ERROR] _SCRemoteQueue_Enqueue:217 remoteQueue=0xa542ef6c0 err=-19641 opType=3 Error occurred when enqueuing data"}
        """

        let summary = MDKReplaydXctraceArtifactParser.summarizeUnifiedLogArtifact(
            outputPath: "/tmp/replayd-log.ndjson",
            logText: logText
        )

        let enqueueSummary = try XCTUnwrap(summary.enqueueFailureSummary)
        XCTAssertEqual(enqueueSummary.eventCount, 3)
        XCTAssertEqual(enqueueSummary.errorHistogram["-19641"], 3)
        XCTAssertEqual(enqueueSummary.operationHistogram["3"], 3)
        XCTAssertEqual(enqueueSummary.messageKindHistogram["generic-enqueue-error"], 3)
        XCTAssertEqual(enqueueSummary.remoteQueueHistogram["0xa542ef6c0"], 3)
        XCTAssertEqual(enqueueSummary.threadHistogram["2068394"], 2)
        XCTAssertEqual(enqueueSummary.threadHistogram["2069384"], 1)
        XCTAssertEqual(enqueueSummary.senderProgramCounterHistogram["766532"], 3)
        XCTAssertEqual(enqueueSummary.imageOffsetHistogram["766532"], 3)
        XCTAssertEqual(enqueueSummary.cadenceClassification, "60hz-like")
        XCTAssertEqual(enqueueSummary.firstEvents.count, 3)
    }
}
