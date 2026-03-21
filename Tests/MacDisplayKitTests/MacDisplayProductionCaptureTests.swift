import CoreMedia
import CoreVideo
import IOSurface
import MacDisplayKitObjCShim
@testable import MacDisplayCaptureKit
import XCTest

final class MacDisplayProductionCaptureTests: XCTestCase {
    func testEncodedCaptureConfigurationDefaultsToCodecFriendlyPanelNativeSurface() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(displayID: 7)

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertEqual(configuration.codec, .hevc)
        XCTAssertEqual(configuration.deliveryMode, .multiplexed)
        XCTAssertEqual(configuration.streamConfiguration.queueDepth, 2)
        XCTAssertEqual(configuration.streamConfiguration.queueProfile, .q2)
        XCTAssertEqual(
            configuration.streamConfiguration.pixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            configuration.resolvedCapturePixelFormat,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    }

    func testEncodedCaptureConfigurationPreservesExplicitCapturePixelFormatOverride() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 9,
            codec: .proResProxy,
            capturePixelFormat: kCVPixelFormatType_32BGRA
        )

        XCTAssertEqual(configuration.codec, .proResProxy)
        XCTAssertEqual(configuration.streamConfiguration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.resolvedCapturePixelFormat, kCVPixelFormatType_32BGRA)
    }

    func testQueueProfileOverridesResolvedQueueDepth() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 10,
            queueDepth: 8,
            queueProfile: .q2
        )

        XCTAssertEqual(configuration.streamConfiguration.queueDepth, 8)
        XCTAssertEqual(configuration.streamConfiguration.queueProfile, .q2)
        XCTAssertEqual(configuration.streamConfiguration.resolvedQueueDepth, 2)
    }

    func testHDR10ConfigurationProducesExpectedTransferAndMetadataPayloadSizes() {
        let hdr10 = MDKVideoHDRConfiguration.hdr10()

        XCTAssertEqual(hdr10.colorPrimaries, .ituR2020)
        XCTAssertEqual(hdr10.transferFunction, .smpteSt2084PQ)
        XCTAssertEqual(hdr10.yCbCrMatrix, .ituR2020)
        XCTAssertEqual(hdr10.masteringDisplayColorVolume?.encodedData.count, 24)
        XCTAssertEqual(hdr10.contentLightLevelInfo?.encodedData.count, 4)
        XCTAssertEqual(hdr10.sessionProperties.count, 6)
    }

    func testHLGConfigurationOmitsMasteringMetadataByDefault() {
        let hlg = MDKVideoHDRConfiguration.hlg()

        XCTAssertEqual(hlg.transferFunction, .ituR2100HLG)
        XCTAssertNil(hlg.masteringDisplayColorVolume)
        XCTAssertNil(hlg.contentLightLevelInfo)
    }

    func testCodecPreferredCapturePixelFormatsMatchProductionDefaults() {
        XCTAssertEqual(MDKVideoEncoderCodec.hevc.preferredCapturePixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(MDKVideoEncoderCodec.h264.preferredCapturePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(MDKVideoEncoderCodec.proResProxy.preferredCapturePixelFormat, kCVPixelFormatType_32BGRA)
    }

    func testCodecRawValuesUseCanonicalExternalNames() {
        XCTAssertEqual(MDKVideoEncoderCodec.h264.rawValue, "h264")
        XCTAssertEqual(MDKVideoEncoderCodec.hevc.rawValue, "hevc")
        XCTAssertEqual(MDKVideoEncoderCodec.proResProxy.rawValue, "prores-proxy")
    }

    func testBackpressurePoliciesMapToStableAsyncStreamPolicies() {
        let oldest = MDKEncodedCaptureBackpressurePolicy.dropOldest(limit: 4).streamBufferingPolicy
        let newest = MDKEncodedCaptureBackpressurePolicy.dropNewest(limit: 3).streamBufferingPolicy
        let unbounded = MDKEncodedCaptureBackpressurePolicy.unbounded.streamBufferingPolicy

        switch oldest {
        case .bufferingOldest(let limit):
            XCTAssertEqual(limit, 4)
        default:
            XCTFail("Expected bufferingOldest policy.")
        }

        switch newest {
        case .bufferingNewest(let limit):
            XCTAssertEqual(limit, 3)
        default:
            XCTFail("Expected bufferingNewest policy.")
        }

        switch unbounded {
        case .unbounded:
            break
        default:
            XCTFail("Expected unbounded policy.")
        }
    }

    func testEncodedFrameDetectsKeyframesAndFormats() throws {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_ContentLightLevelInfo: MDKVideoContentLightLevelInfo.hdr10Default().encodedData as CFData
        ]
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_HEVC,
                width: 3840,
                height: 2160,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 42, timescale: 120),
            decodeTimeStamp: .invalid
        )
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )

        let encodedFrame = MDKEncodedFrame(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            codec: .hevc,
            sourceSequenceNumber: 77,
            sourceDisplayTime: 88,
            outputCallbackLatencyMilliseconds: 3.2
        )

        XCTAssertTrue(encodedFrame.isKeyFrame)
        XCTAssertTrue(encodedFrame.isHDRSignaled)
        XCTAssertTrue(encodedFrame.hdrValidationReport.isPQ)
        XCTAssertTrue(encodedFrame.hdrValidationReport.isWideGamut)
        XCTAssertEqual(encodedFrame.presentationTimeStamp, CMTime(value: 42, timescale: 120))
        XCTAssertEqual(encodedFrame.formatDescriptionExtensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
    }

    func testProResDefaultsToBGRACaptureFriendlySurface() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 10,
            codec: .proResProxy
        )

        XCTAssertEqual(
            configuration.streamConfiguration.pixelFormat,
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            configuration.resolvedCapturePixelFormat,
            kCVPixelFormatType_32BGRA
        )
    }

    func testCallbackOnlyConfigurationRequiresCallbackConsumer() async {
        let session = makeTestSession(
            configuration: .panelNative(
                displayID: 12,
                deliveryMode: .callbackOnly
            ),
            source: TestSourceSession(),
            processorFactory: { outputHandler, failureHandler in
                let processor = TestProcessor { _, _ in }
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        do {
            try await session.start()
            XCTFail("Expected callback-only session start without callbacks to fail.")
        } catch let error as MDKEncodedCaptureSessionError {
            XCTAssertEqual(error, .callbackRequiredForCallbackOnlyMode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCallbackOnlyConfigurationTerminatesFrameStreamsImmediately() async {
        let session = makeTestSession(
            configuration: .panelNative(
                displayID: 13,
                deliveryMode: .callbackOnly
            ),
            source: TestSourceSession(),
            processorFactory: { outputHandler, failureHandler in
                let processor = TestProcessor { _, _ in }
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        let stream = await session.makeFrameStream()
        do {
            for try await _ in stream {
                XCTFail("Callback-only frame stream should terminate immediately.")
            }
            XCTFail("Expected frame stream to finish with an error.")
        } catch let error as MDKEncodedCaptureSessionError {
            XCTAssertEqual(error, .frameStreamUnsupportedInCallbackOnlyMode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEncodedCaptureSessionEmitsFramesFromProcessorOutput() async throws {
        let source = TestSourceSession()
        let sampleBuffer = TestSendableSampleBufferBox(sampleBuffer: try Self.makeTestSampleBuffer())
        let processor = TestProcessor { outputHandler, _ in
            outputHandler(
                MDKEncodedFrame(
                    sampleBuffer: sampleBuffer.sampleBuffer,
                    codec: .hevc,
                    sourceSequenceNumber: 1,
                    sourceDisplayTime: 2,
                    outputCallbackLatencyMilliseconds: 1.5
                )
            )
        }
        let session = makeTestSession(
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        let frameStream = await session.makeFrameStream()
        _ = frameStream
        try await session.start()
        source.emitFrame(surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 20_000_000)
        let stats = await session.statisticsSnapshot()
        XCTAssertEqual(stats.emittedFrameCount, 1)
        XCTAssertTrue(stats.isRunning)

        await session.stop()
    }

    func testEncodedCaptureSessionInvokesDirectCallbackConsumer() async throws {
        let source = TestSourceSession()
        let sampleBuffer = TestSendableSampleBufferBox(sampleBuffer: try Self.makeTestSampleBuffer())
        let processor = TestProcessor { outputHandler, _ in
            outputHandler(
                MDKEncodedFrame(
                    sampleBuffer: sampleBuffer.sampleBuffer,
                    codec: .hevc,
                    sourceSequenceNumber: 4,
                    sourceDisplayTime: 9,
                    outputCallbackLatencyMilliseconds: 0.6
                )
            )
        }
        let session = makeTestSession(
            configuration: .panelNative(
                displayID: 11,
                deliveryMode: .callbackOnly
            ),
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )
        let callbackRecorder = CallbackRecorder()

        try await session.start(
            callbacks: MDKEncodedCaptureCallbacks(
                frameHandler: { frame in
                    callbackRecorder.record(frame: frame)
                }
            )
        )
        source.emitFrame(displayTime: 9, surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 20_000_000)

        let stats = await session.statisticsSnapshot()
        let recordedFrameCount = await callbackRecorder.frameCount
        let recordedSourceDisplayTime = await callbackRecorder.lastSourceDisplayTime
        XCTAssertEqual(stats.emittedFrameCount, 1)
        XCTAssertEqual(recordedFrameCount, 1)
        XCTAssertEqual(recordedSourceDisplayTime, 9)

        await session.stop()
    }

    func testEncodedCaptureSessionStopsWhenRestartLimitIsReached() async throws {
        let source = TestSourceSession()
        let processor = TestProcessor { _, failureHandler in
            failureHandler("synthetic-failure")
        }
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 17,
            recoveryPolicy: .init(
                automaticallyRestartOnFailure: true,
                maximumAutomaticRestartCount: 0,
                restartDelay: 0
            )
        )
        let session = makeTestSession(
            configuration: configuration,
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        let frameStream = await session.makeFrameStream()
        _ = frameStream
        try await session.start()
        source.emitFrame(surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 20_000_000)

        let stats = await session.statisticsSnapshot()
        XCTAssertFalse(stats.isRunning)
        XCTAssertEqual(stats.processingFailureCount, 1)
        XCTAssertEqual(stats.lastErrorDescription, "synthetic-failure")
        XCTAssertEqual(source.stopCallCount, 1)
    }

    func testCancelledScheduledRestartDoesNotRestartReplacementRuntime() async throws {
        let factory = TestSourceFactory()
        let processorFactory = TestProcessorFactory { _, failureHandler in
            failureHandler("restart-me")
        }
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 23,
            recoveryPolicy: .init(
                automaticallyRestartOnFailure: true,
                maximumAutomaticRestartCount: 2,
                restartDelay: 0.05
            )
        )
        let session = MDKEncodedCaptureSession(
            configuration: configuration,
            sourceFactory: { _, frameHandler in
                factory.makeSource(frameHandler: frameHandler)
            },
            processorFactory: { _, outputHandler, failureHandler in
                processorFactory.makeProcessor(outputHandler: outputHandler, failureHandler: failureHandler)
            }
        )

        try await session.start()
        factory.sources[0].emitFrame(surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 10_000_000)
        try await session.restart()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(factory.sources.count, 2)
        XCTAssertEqual(processorFactory.createdProcessorCount, 2)
        let stats = await session.statisticsSnapshot()
        XCTAssertEqual(stats.automaticRestartCount, 0)
        XCTAssertTrue(stats.isRunning)

        await session.stop()
    }

    func testEncodedFrameHDRValidationReportSurfacesTransferAndMetadataPresence() throws {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        let masteringData = MDKVideoMasteringDisplayColorVolume.hdr10Default().encodedData
        let contentLightData = MDKVideoContentLightLevelInfo.hdr10Default().encodedData
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume: masteringData as CFData,
            kCMFormatDescriptionExtension_ContentLightLevelInfo: contentLightData as CFData
        ]
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_HEVC,
                width: 3840,
                height: 2160,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 1, timescale: 120),
            decodeTimeStamp: .invalid
        )
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )

        let frame = MDKEncodedFrame(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            codec: .hevc,
            sourceSequenceNumber: 1,
            sourceDisplayTime: 1,
            outputCallbackLatencyMilliseconds: nil
        )

        XCTAssertTrue(frame.hdrValidationReport.isHDRSignaled)
        XCTAssertEqual(frame.hdrValidationReport.transferFunction, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertTrue(frame.hdrValidationReport.hasMasteringDisplayColorVolume)
        XCTAssertTrue(frame.hdrValidationReport.hasContentLightLevelInfo)
    }

    func testEncodedCaptureSessionPublishesLifecycleEvents() async throws {
        let source = TestSourceSession()
        let sampleBuffer = TestSendableSampleBufferBox(sampleBuffer: try Self.makeTestSampleBuffer())
        let processor = TestProcessor { outputHandler, _ in
            outputHandler(
                MDKEncodedFrame(
                    sampleBuffer: sampleBuffer.sampleBuffer,
                    codec: .hevc,
                    sourceSequenceNumber: 1,
                    sourceDisplayTime: 3,
                    outputCallbackLatencyMilliseconds: 0.8
                )
            )
        }
        let session = makeTestSession(
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        let eventStream = await session.makeEventStream()
        var eventIterator = eventStream.makeAsyncIterator()
        try await session.start()
        source.emitFrame(displayTime: 3, surface: Self.makeTestSurface())

        let started = await eventIterator.next()
        XCTAssertEqual(started?.kind, .started)

        let frameDropped = await eventIterator.next()
        XCTAssertEqual(frameDropped?.kind, .droppedFrame)
        XCTAssertEqual(frameDropped?.sourceDisplayTime, 3)

        await session.stop()
        let stopped = await eventIterator.next()
        XCTAssertEqual(stopped?.kind, .stopped)
    }

    func testEncodedCaptureSessionDeliversFramesThroughCallbackConsumer() async throws {
        let source = TestSourceSession()
        let sampleBuffer = TestSendableSampleBufferBox(sampleBuffer: try Self.makeTestSampleBuffer())
        let processor = TestProcessor { outputHandler, _ in
            outputHandler(
                MDKEncodedFrame(
                    sampleBuffer: sampleBuffer.sampleBuffer,
                    codec: .hevc,
                    sourceSequenceNumber: 11,
                    sourceDisplayTime: 17,
                    outputCallbackLatencyMilliseconds: 0.6
                )
            )
        }
        let session = makeTestSession(
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )
        let recorder = TestCallbackRecorder()

        try await session.start(
            callbacks: MDKEncodedCaptureCallbacks(
                frameHandler: { frame in
                    Task {
                        await recorder.record(frame: frame)
                    }
                },
                eventHandler: { event in
                    Task {
                        await recorder.record(event: event)
                    }
                }
            )
        )

        source.emitFrame(displayTime: 17, surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 20_000_000)

        let stats = await session.statisticsSnapshot()
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(stats.emittedFrameCount, 1)
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.lastSourceDisplayTime, 17)
        XCTAssertEqual(snapshot.eventKinds.first, .started)

        await session.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        let stoppedSnapshot = await recorder.snapshot()
        XCTAssertEqual(stoppedSnapshot.eventKinds.last, .stopped)
    }

    private typealias TestProcessorFactoryClosure = @Sendable (
        @escaping @Sendable (MDKEncodedFrame) -> Void,
        @escaping @Sendable (String) -> Void
    ) -> any MDKEncodedCaptureProcessorRuntime

    private func makeTestSession(
        configuration: MDKEncodedCaptureConfiguration = .panelNative(displayID: 11),
        source: TestSourceSession,
        processorFactory: @escaping TestProcessorFactoryClosure
    ) -> MDKEncodedCaptureSession {
        MDKEncodedCaptureSession(
            configuration: configuration,
            sourceFactory: { _, frameHandler in
                source.frameHandler = frameHandler
                return source
            },
            processorFactory: { _, outputHandler, failureHandler in
                processorFactory(outputHandler, failureHandler)
            }
        )
    }

    private static func makeTestSurface(
        width: Int = 64,
        height: Int = 64,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) -> IOSurface {
        guard let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfacePixelFormat: pixelFormat,
            kIOSurfaceBytesPerElement: 4
        ] as CFDictionary) else {
            fatalError("Expected test IOSurface allocation to succeed.")
        }
        return surface
    }

    private static func makeTestSampleBuffer() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_HEVC,
                width: 1920,
                height: 1080,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 10, timescale: 120),
            decodeTimeStamp: .invalid
        )
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

private final class TestSourceSession: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    var frameHandler: (@Sendable (MDKCaptureFrame) -> Void)?
    var startCallCount: Int = 0
    var stopCallCount: Int = 0

    func start() throws {
        startCallCount += 1
    }

    func stop() -> Int32 {
        stopCallCount += 1
        return 0
    }

    func emitFrame(
        displayTime: UInt64 = 1,
        surface: IOSurface
    ) {
        frameHandler?(
            MDKCaptureFrame(
                sequenceNumber: displayTime,
                displayTime: displayTime,
                surfaceID: IOSurfaceGetID(surface),
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface),
                pixelFormat: IOSurfaceGetPixelFormat(surface),
                surface: MDKCaptureSurface(ioSurface: surface)
            )
        )
    }
}

private final class TestProcessor: MDKEncodedCaptureProcessorRuntime, @unchecked Sendable {
    private let behavior: @Sendable (
        @escaping @Sendable (MDKEncodedFrame) -> Void,
        @escaping @Sendable (String) -> Void
    ) -> Void
    private var outputHandler: (@Sendable (MDKEncodedFrame) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?
    private var emittedFrameCount: UInt64 = 0
    private var failureCount: UInt64 = 0

    init(
        behavior: @escaping @Sendable (
            @escaping @Sendable (MDKEncodedFrame) -> Void,
            @escaping @Sendable (String) -> Void
        ) -> Void
    ) {
        self.behavior = behavior
    }

    func bind(
        outputHandler: @escaping @Sendable (MDKEncodedFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        self.outputHandler = outputHandler
        self.failureHandler = failureHandler
    }

    func process(frame: MDKCaptureFrame) throws {
        guard let outputHandler, let failureHandler else {
            XCTFail("Test processor was not bound before use.")
            return
        }
        let countingOutputHandler: @Sendable (MDKEncodedFrame) -> Void = { [weak self] frame in
            self?.emittedFrameCount += 1
            outputHandler(frame)
        }
        let countingFailureHandler: @Sendable (String) -> Void = { [weak self] description in
            self?.failureCount += 1
            failureHandler(description)
        }
        behavior(countingOutputHandler, countingFailureHandler)
    }

    func finalize() -> MDKCaptureFrameProcessingSummary? {
        liveSummary()
    }

    func liveSummary() -> MDKCaptureFrameProcessingSummary? {
        MDKCaptureFrameProcessingSummary(
            processedFrameCount: emittedFrameCount,
            processingFailureCount: failureCount,
            processingErrorHistogram: [:],
            outputCallbackCount: emittedFrameCount,
            completedOutputFrameCount: emittedFrameCount,
            outputCallbackStatusHistogram: [:],
            outputCallbackLatencyHistogram: [:],
            minOutputCallbackLatencyMilliseconds: nil,
            maxOutputCallbackLatencyMilliseconds: nil,
            notes: []
        )
    }
}

private actor TestCallbackRecorder {
    struct Snapshot {
        let frameCount: Int
        let lastSourceDisplayTime: UInt64?
        let eventKinds: [MDKEncodedCaptureSessionEventKind]
    }

    private(set) var frameCount: Int = 0
    private(set) var lastSourceDisplayTime: UInt64?
    private(set) var eventKinds: [MDKEncodedCaptureSessionEventKind] = []

    func record(frame: MDKEncodedFrame) {
        frameCount += 1
        lastSourceDisplayTime = frame.sourceDisplayTime
    }

    func record(event: MDKEncodedCaptureSessionEvent) {
        eventKinds.append(event.kind)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            frameCount: frameCount,
            lastSourceDisplayTime: lastSourceDisplayTime,
            eventKinds: eventKinds
        )
    }
}

private final class TestSourceFactory: @unchecked Sendable {
    private(set) var sources: [TestSourceSession] = []

    func makeSource(frameHandler: @escaping @Sendable (MDKCaptureFrame) -> Void) -> TestSourceSession {
        let source = TestSourceSession()
        source.frameHandler = frameHandler
        sources.append(source)
        return source
    }
}

private final class TestProcessorFactory: @unchecked Sendable {
    private let behavior: @Sendable (
        @escaping @Sendable (MDKEncodedFrame) -> Void,
        @escaping @Sendable (String) -> Void
    ) -> Void
    private(set) var createdProcessorCount: Int = 0

    init(
        behavior: @escaping @Sendable (
            @escaping @Sendable (MDKEncodedFrame) -> Void,
            @escaping @Sendable (String) -> Void
        ) -> Void
    ) {
        self.behavior = behavior
    }

    func makeProcessor(
        outputHandler: @escaping @Sendable (MDKEncodedFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) -> any MDKEncodedCaptureProcessorRuntime {
        createdProcessorCount += 1
        let processor = TestProcessor(behavior: behavior)
        processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
        return processor
    }
}

private final class TestSendableSampleBufferBox: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer

    init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

private actor CallbackRecorder {
    private(set) var frameCount: UInt64 = 0
    private(set) var lastSourceDisplayTime: UInt64?

    nonisolated func record(frame: MDKEncodedFrame) {
        Task {
            await store(frame: frame)
        }
    }

    private func store(frame: MDKEncodedFrame) {
        frameCount += 1
        lastSourceDisplayTime = frame.sourceDisplayTime
    }
}
