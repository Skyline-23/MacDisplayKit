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
                MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchedLines: ["rqSenderHandleDequeue"]),
                MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchedLines: ["CGYDisplayStreamNotification_server"]),
                MDKReplaydProducerSampleIndicator(name: "slcontentstream", pattern: "SLContentStream", matchedLines: ["SLContentStream"])
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
                MDKReplaydProducerSampleIndicator(name: "producer-read-queue", pattern: "rq", matchedLines: []),
                MDKReplaydProducerSampleIndicator(name: "skylight-display-stream", pattern: "CGY", matchedLines: ["CGYDisplayStreamNotification_server"]),
                MDKReplaydProducerSampleIndicator(name: "slcontentstream", pattern: "SLContentStream", matchedLines: ["SLContentStream"])
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
    }
}
