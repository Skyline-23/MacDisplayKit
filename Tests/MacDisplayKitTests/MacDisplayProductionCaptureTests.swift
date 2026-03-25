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

    func testEncodedCaptureConfigurationPrefersPrivateDirectIOSurfaceWhenAvailable() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(displayID: 7)

        XCTAssertEqual(
            configuration.resolvedSourceBackend(
                using: .init(
                    desktopCaptureAvailable: true,
                    displayIOSurfaceCaptureAvailable: true,
                    displayIOSurfaceCaptureWithOptionsAvailable: true,
                    displayIOSurfaceProxyCaptureAvailable: true,
                    displayStreamProxyAvailable: true,
                    extendedRangeOptionAvailable: true
                )
            ),
            .privateDirectIOSurface
        )
    }

    func testEncodedCaptureConfigurationFallsBackToPrivateDirectIOSurfaceWithoutProxySupport() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(displayID: 7)

        XCTAssertEqual(
            configuration.resolvedSourceBackend(
                using: .init(
                    desktopCaptureAvailable: false,
                    displayIOSurfaceCaptureAvailable: true,
                    displayIOSurfaceCaptureWithOptionsAvailable: true,
                    displayIOSurfaceProxyCaptureAvailable: false,
                    displayStreamProxyAvailable: false,
                    extendedRangeOptionAvailable: false
                )
            ),
            .privateDirectIOSurface
        )
    }

    func testEncodedCaptureConfigurationFallsBackToSkyLightWithoutPrivateIOSurfaceSupport() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(displayID: 7)

        XCTAssertEqual(
            configuration.resolvedSourceBackend(
                using: .init(
                    desktopCaptureAvailable: true,
                    displayIOSurfaceCaptureAvailable: false,
                    displayIOSurfaceCaptureWithOptionsAvailable: false,
                    displayIOSurfaceProxyCaptureAvailable: false,
                    displayStreamProxyAvailable: true,
                    extendedRangeOptionAvailable: false
                )
            ),
            .skyLightDisplayStream
        )
    }

    func testEncodedCaptureConfigurationKeepsPrivateIOSurfaceForHDRWithoutExtendedRangeHints() {
        let configuration = MDKEncodedCaptureConfiguration.panelNative(
            displayID: 7,
            hdrConfiguration: .hdr10()
        )

        XCTAssertEqual(
            configuration.resolvedSourceBackend(
                using: .init(
                    desktopCaptureAvailable: false,
                    displayIOSurfaceCaptureAvailable: true,
                    displayIOSurfaceCaptureWithOptionsAvailable: false,
                    displayIOSurfaceProxyCaptureAvailable: false,
                    displayStreamProxyAvailable: false,
                    extendedRangeOptionAvailable: false
                )
            ),
            .privateDirectIOSurface
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

    func testAudioCaptureConfigurationTracksMicrophoneAndSystemOutputSources() throws {
        let microphone = MDKAudioCaptureConfiguration.microphone(inputID: "mic-1")
        let systemOutput = MDKAudioCaptureConfiguration.systemOutput(displayID: 99)

        XCTAssertEqual(microphone.source, .microphone(inputID: "mic-1"))
        XCTAssertEqual(microphone.sampleRate, 48_000)
        XCTAssertEqual(microphone.channelCount, 2)
        XCTAssertEqual(microphone.frameSize, 480)
        XCTAssertEqual(systemOutput.source, .systemOutput(displayID: 99, excludesCurrentProcessAudio: false))

        let encoded = try JSONEncoder().encode(systemOutput)
        let decoded = try JSONDecoder().decode(MDKAudioCaptureConfiguration.self, from: encoded)
        XCTAssertEqual(decoded, systemOutput)
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

    func testAudioCallbackOnlyConfigurationRequiresCallbackConsumer() async {
        let session = makeAudioTestSession(
            configuration: .microphone(deliveryMode: .callbackOnly),
            source: TestAudioSourceSession()
        )

        do {
            try await session.start()
            XCTFail("Expected callback-only audio session start without callbacks to fail.")
        } catch let error as MDKAudioCaptureSessionError {
            XCTAssertEqual(error, .callbackRequiredForCallbackOnlyMode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAudioSessionDeliversFramesToCallbacksAndEvents() async throws {
        let recorder = TestAudioCallbackRecorder()
        let source = TestAudioSourceSession()
        let session = makeAudioTestSession(source: source)

        try await session.start(
            callbacks: .init(
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

        source.emitFrame(
            .init(
                sequenceNumber: 7,
                hostTimeNanoseconds: 700,
                sampleRate: 48_000,
                channelCount: 2,
                frameCount: 480,
                pcmFloat32LE: Data(repeating: 0, count: 480 * 2 * MemoryLayout<Float>.size)
            )
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await recorder.snapshot()
        let stats = await session.statisticsSnapshot()
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.lastSequenceNumber, 7)
        XCTAssertEqual(snapshot.eventKinds.first, .started)
        XCTAssertEqual(stats.emittedFrameCount, 1)

        await session.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        let stoppedSnapshot = await recorder.snapshot()
        XCTAssertEqual(stoppedSnapshot.eventKinds.last, .stopped)
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
            sourceFactory: { _, _, frameHandler in
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

    func testEncodedFrameHDRValidationReportDetectsHEVCStaticMetadataSEIInBitstream() throws {
        let hdrConfiguration = MDKVideoHDRConfiguration(
            colorPrimaries: .p3D65,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR709,
            masteringDisplayColorVolume: ApolloStyleHDRMetadata.p3Mastering,
            contentLightLevelInfo: ApolloStyleHDRMetadata.p3ContentLight
        )
        let payload = try XCTUnwrap(
            MDKHEVCHDRStaticMetadataTransport.makeLengthPrefixedPrefixSEINALUnit(
                nalUnitHeaderLength: 4,
                masteringDisplayColorVolume: hdrConfiguration.masteringDisplayColorVolume,
                contentLightLevelInfo: hdrConfiguration.contentLightLevelInfo
            )
        )
        let sampleBuffer = try Self.makeCompressedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC,
            formatDescriptionExtensions: [
                kCMFormatDescriptionExtension_ColorPrimaries as String: kCMFormatDescriptionColorPrimaries_P3_D65 as String,
                kCMFormatDescriptionExtension_TransferFunction as String: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                kCMFormatDescriptionExtension_YCbCrMatrix as String: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
            ],
            payload: payload
        )

        let frame = MDKEncodedFrame(
            sampleBuffer: sampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 9,
            sourceDisplayTime: 9,
            outputCallbackLatencyMilliseconds: nil
        )

        XCTAssertTrue(frame.hdrValidationReport.hasMasteringDisplayColorVolume)
        XCTAssertTrue(frame.hdrValidationReport.hasContentLightLevelInfo)
        XCTAssertTrue(frame.hdrValidationReport.isHDRSignaled)
    }

    func testHEVCHDRStaticMetadataTransportAugmentsKeyframesWhenVTOutputOmitsMetadata() throws {
        let hdrConfiguration = MDKVideoHDRConfiguration(
            colorPrimaries: .p3D65,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR709,
            masteringDisplayColorVolume: ApolloStyleHDRMetadata.p3Mastering,
            contentLightLevelInfo: ApolloStyleHDRMetadata.p3ContentLight
        )
        let sampleBuffer = try Self.makeCompressedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC,
            formatDescriptionExtensions: [
                kCMFormatDescriptionExtension_ColorPrimaries as String: kCMFormatDescriptionColorPrimaries_P3_D65 as String,
                kCMFormatDescriptionExtension_TransferFunction as String: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                kCMFormatDescriptionExtension_YCbCrMatrix as String: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
            ],
            payload: Self.makeLengthPrefixedNALUnit(
                nalUnitHeaderLength: 4,
                bytes: Data([0x26, 0x01, 0x88, 0x99])
            )
        )

        let augmentedSampleBuffer = try XCTUnwrap(
            MDKHEVCHDRStaticMetadataTransport.makeAugmentedSampleBufferIfNeeded(
                sampleBuffer: sampleBuffer,
                hdrConfiguration: hdrConfiguration,
                isKeyFrame: true
            )
        )
        let frame = MDKEncodedFrame(
            sampleBuffer: augmentedSampleBuffer,
            codec: .hevc,
            sourceSequenceNumber: 10,
            sourceDisplayTime: 10,
            outputCallbackLatencyMilliseconds: nil
        )

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

    func testEncodedCaptureSessionKeepsSourceFramesPendingUntilProcessorReleasesThem() async throws {
        let source = TestSourceSession()
        let processor = BlockingReleaseProcessor()
        let configuration = MDKEncodedCaptureConfiguration.panelNative(displayID: 11)
        let expectedPendingLimit = switch configuration.resolvedSourceBackend {
        case .privateDirectIOSurface:
            max(configuration.resolvedPrivateCaptureSurfaceCount - 1, 1)
        case .skyLightDisplayStream:
            {
                let effectiveQueueDepth = max(configuration.streamConfiguration.resolvedQueueDepth, 1)
                if configuration.targetFrameRate >= 100 {
                    return min(max(effectiveQueueDepth * 3, 10), 16)
                } else if configuration.targetFrameRate >= 60 {
                    return min(max(effectiveQueueDepth * 2, 3), 10)
                }
                return min(max(effectiveQueueDepth * 2, 2), 8)
            }()
        }
        let expectedDroppedCount = UInt64(10 - expectedPendingLimit)
        let session = makeTestSession(
            configuration: configuration,
            source: source,
            processorFactory: { _, _ in
                processor
            }
        )

        try await session.start()

        for displayTime in 1...10 {
            source.emitFrame(displayTime: UInt64(displayTime), surface: Self.makeTestSurface())
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let saturatedStats = await session.statisticsSnapshot()
        XCTAssertEqual(saturatedStats.droppedFrameCount, expectedDroppedCount)
        XCTAssertEqual(processor.pendingReleaseCount, expectedPendingLimit)

        processor.releaseOne()
        source.emitFrame(displayTime: 11, surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 50_000_000)

        let resumedStats = await session.statisticsSnapshot()
        XCTAssertEqual(resumedStats.droppedFrameCount, expectedDroppedCount)
        XCTAssertEqual(processor.pendingReleaseCount, expectedPendingLimit)

        await session.stop()
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

    func testCallbackOnlyStatisticsExposeSourceCadenceNotes() async throws {
        let source = TestSourceSession()
        let sampleBuffer = TestSendableSampleBufferBox(sampleBuffer: try Self.makeTestSampleBuffer())
        let processor = TestProcessor { outputHandler, _ in
            outputHandler(
                MDKEncodedFrame(
                    sampleBuffer: sampleBuffer.sampleBuffer,
                    codec: .hevc,
                    sourceSequenceNumber: 1,
                    sourceDisplayTime: 1,
                    outputCallbackLatencyMilliseconds: 0.4
                )
            )
        }
        let session = makeTestSession(
            configuration: .panelNative(
                displayID: 14,
                deliveryMode: .callbackOnly
            ),
            source: source,
            processorFactory: { outputHandler, failureHandler in
                processor.bind(outputHandler: outputHandler, failureHandler: failureHandler)
                return processor
            }
        )

        try await session.start(
            callbacks: MDKEncodedCaptureCallbacks(
                frameHandler: { _ in },
                eventHandler: nil
            )
        )

        source.emitFrame(displayTime: 400_000, surface: Self.makeTestSurface())
        source.emitFrame(displayTime: 1_000_000, surface: Self.makeTestSurface())
        try await Task.sleep(nanoseconds: 20_000_000)

        let statistics = await session.statisticsSnapshot()
        XCTAssertTrue(statistics.notes.contains("sourceFrameCount=2"))
        XCTAssertTrue(statistics.notes.contains(where: { $0.hasPrefix("sourceApproxFrameRate=") }))
        XCTAssertTrue(statistics.notes.contains(where: { $0.hasPrefix("sourceAverageDisplayDeltaMilliseconds=") }))

        await session.stop()
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
            sourceFactory: { _, _, frameHandler in
                source.frameHandler = frameHandler
                return source
            },
            processorFactory: { _, outputHandler, failureHandler in
                processorFactory(outputHandler, failureHandler)
            }
        )
    }

    private func makeAudioTestSession(
        configuration: MDKAudioCaptureConfiguration = .microphone(),
        source: TestAudioSourceSession
    ) -> MDKAudioCaptureSession {
        MDKAudioCaptureSession(
            configuration: configuration,
            sourceFactory: { _, frameHandler, _ in
                source.frameHandler = frameHandler
                return source
            }
        )
    }

    private static func makeTestSurface(
        width: Int = 64,
        height: Int = 64,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) -> IOSurfaceRef {
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

    private static func makeCompressedSampleBuffer(
        codecType: CMVideoCodecType,
        formatDescriptionExtensions: [String: Any],
        payload: Data
    ) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: codecType,
                width: 1920,
                height: 1080,
                extensions: formatDescriptionExtensions as CFDictionary,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: payload.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: payload.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let replaceStatus = payload.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: try! XCTUnwrap(blockBuffer),
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        XCTAssertEqual(replaceStatus, kCMBlockBufferNoErr)

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(value: 10, timescale: 120),
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: try XCTUnwrap(blockBuffer),
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: [timing],
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private static func makeLengthPrefixedNALUnit(
        nalUnitHeaderLength: Int,
        bytes: Data
    ) -> Data {
        var prefix = Data(repeating: 0, count: nalUnitHeaderLength)
        for byteIndex in 0..<nalUnitHeaderLength {
            let shift = (nalUnitHeaderLength - byteIndex - 1) * 8
            prefix[byteIndex] = UInt8((bytes.count >> shift) & 0xFF)
        }
        var output = Data()
        output.append(prefix)
        output.append(bytes)
        return output
    }
}

private enum ApolloStyleHDRMetadata {
    static let p3Mastering = MDKVideoMasteringDisplayColorVolume(
        redPrimary: MDKVideoChromaticityPoint(x: 0.6800, y: 0.3200),
        greenPrimary: MDKVideoChromaticityPoint(x: 0.2650, y: 0.6900),
        bluePrimary: MDKVideoChromaticityPoint(x: 0.1500, y: 0.0600),
        whitePoint: MDKVideoChromaticityPoint(x: 0.3127, y: 0.3290),
        maxLuminance: 1000.0,
        minLuminance: 0.001
    )

    static let p3ContentLight = MDKVideoContentLightLevelInfo(
        maximumContentLightLevel: 1000,
        maximumFrameAverageLightLevel: 400
    )
}

private final class TestSourceSession: MDKEncodedCaptureSourceRuntime, @unchecked Sendable {
    var frameHandler: (@Sendable (MDKCaptureFrame) -> Void)?
    var startCallCount: Int = 0
    var stopCallCount: Int = 0
    var runtimeDescription: String = "test-source"

    func start() throws {
        startCallCount += 1
    }

    func stop() -> Int32 {
        stopCallCount += 1
        return 0
    }

    func emitFrame(
        displayTime: UInt64 = 1,
        surface: IOSurfaceRef
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

private final class TestAudioSourceSession: MDKAudioCaptureSourceRuntime, @unchecked Sendable {
    var frameHandler: (@Sendable (MDKAudioFrame) -> Void)?
    var startCallCount: Int = 0
    var stopCallCount: Int = 0

    func start() async throws {
        startCallCount += 1
    }

    func stop() async -> Int32 {
        stopCallCount += 1
        return 0
    }

    func emitFrame(_ frame: MDKAudioFrame) {
        frameHandler?(frame)
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

    func process(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
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
        releaseSourceFrame()
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

private final class BlockingReleaseProcessor: MDKEncodedCaptureProcessorRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingReleaseHandlers: [@Sendable () -> Void] = []

    var pendingReleaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingReleaseHandlers.count
    }

    func process(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        pendingReleaseHandlers.append(releaseSourceFrame)
        lock.unlock()
    }

    func finalize() -> MDKCaptureFrameProcessingSummary? {
        liveSummary()
    }

    func liveSummary() -> MDKCaptureFrameProcessingSummary? {
        MDKCaptureFrameProcessingSummary(
            processedFrameCount: 0,
            processingFailureCount: 0,
            processingErrorHistogram: [:],
            outputCallbackCount: 0,
            completedOutputFrameCount: 0,
            outputCallbackStatusHistogram: [:],
            outputCallbackLatencyHistogram: [:],
            minOutputCallbackLatencyMilliseconds: nil,
            maxOutputCallbackLatencyMilliseconds: nil,
            notes: []
        )
    }

    func releaseOne() {
        let releaseHandler: (@Sendable () -> Void)?
        lock.lock()
        if pendingReleaseHandlers.isEmpty {
            releaseHandler = nil
        } else {
            releaseHandler = pendingReleaseHandlers.removeFirst()
        }
        lock.unlock()
        releaseHandler?()
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

private actor TestAudioCallbackRecorder {
    struct Snapshot {
        let frameCount: Int
        let lastSequenceNumber: UInt64?
        let eventKinds: [MDKAudioCaptureSessionEventKind]
    }

    private(set) var frameCount: Int = 0
    private(set) var lastSequenceNumber: UInt64?
    private(set) var eventKinds: [MDKAudioCaptureSessionEventKind] = []

    func record(frame: MDKAudioFrame) {
        frameCount += 1
        lastSequenceNumber = frame.sequenceNumber
    }

    func record(event: MDKAudioCaptureSessionEvent) {
        eventKinds.append(event.kind)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            frameCount: frameCount,
            lastSequenceNumber: lastSequenceNumber,
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
