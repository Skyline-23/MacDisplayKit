import AudioToolbox
import CoreMedia
import Foundation
import MacDisplayKitObjCShim
import ScreenCaptureKit

protocol MDKAudioCaptureSourceRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async -> Int32
}

typealias MDKAudioCaptureSourceFactory = @Sendable (
    MDKAudioCaptureConfiguration,
    @escaping @Sendable (MDKAudioFrame) -> Void,
    @escaping @Sendable (String) -> Void
) -> any MDKAudioCaptureSourceRuntime

private final class MDKShimMicrophoneAudioCaptureSourceRuntime: MDKAudioCaptureSourceRuntime, @unchecked Sendable {
    private let shimSession: MDKShimMicrophoneCaptureSession

    init(
        configuration: MDKAudioCaptureConfiguration,
        frameHandler: @escaping @Sendable (MDKAudioFrame) -> Void
    ) {
        let inputID: String?
        switch configuration.source {
        case .microphone(let selectedInputID):
            inputID = selectedInputID
        case .systemOutput:
            inputID = nil
        }

        shimSession = MDKShimMicrophoneCaptureSession(
            inputID: inputID,
            sampleRate: UInt(configuration.sampleRate),
            frameSize: UInt(configuration.frameSize),
            channels: UInt(configuration.channelCount)
        ) { hostTimeNanoseconds, pcmFloat32LE, frameCount, channelCount, sampleRate in
            frameHandler(
                MDKAudioFrame(
                    sequenceNumber: hostTimeNanoseconds,
                    hostTimeNanoseconds: hostTimeNanoseconds,
                    sampleRate: Int(sampleRate),
                    channelCount: Int(channelCount),
                    frameCount: Int(frameCount),
                    pcmFloat32LE: pcmFloat32LE
                )
            )
        }
    }

    func start() async throws {
        try shimSession.start()
    }

    func stop() async -> Int32 {
        shimSession.stop()
    }
}

private final class MDKSystemAudioCaptureSourceRuntime: NSObject, MDKAudioCaptureSourceRuntime, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let configuration: MDKAudioCaptureConfiguration
    private let frameHandler: @Sendable (MDKAudioFrame) -> Void
    private let failureHandler: @Sendable (String) -> Void
    private let sampleHandlerQueue: DispatchQueue
    private var stream: SCStream?
    private var nextSequenceNumber: UInt64 = 0

    init(
        configuration: MDKAudioCaptureConfiguration,
        frameHandler: @escaping @Sendable (MDKAudioFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        self.configuration = configuration
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
        self.sampleHandlerQueue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.audio.system-output.\(configuration.source.debugIdentifier)"
        )
        super.init()
    }

    func start() async throws {
        guard case .systemOutput(let displayID, let excludesCurrentProcessAudio) = configuration.source else {
            throw MDKAudioCaptureSessionError.inputUnavailable(description: "Invalid system-output source configuration.")
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first(where: { UInt32($0.displayID) == displayID }) else {
            throw MDKAudioCaptureSessionError.inputUnavailable(
                description: "Unable to resolve display \(displayID) for system-output capture."
            )
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = 2
        streamConfiguration.height = 2
        streamConfiguration.minimumFrameInterval = .zero
        streamConfiguration.queueDepth = 2
        streamConfiguration.capturesAudio = true
        streamConfiguration.sampleRate = configuration.sampleRate
        streamConfiguration.channelCount = configuration.channelCount
        streamConfiguration.excludesCurrentProcessAudio = excludesCurrentProcessAudio

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        self.stream = stream
    }

    func stop() async -> Int32 {
        guard let stream else {
            return 0
        }
        self.stream = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }
        return 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else {
            return
        }

        do {
            nextSequenceNumber += 1
            let frame = try MDKMakeAudioFrame(
                sequenceNumber: nextSequenceNumber,
                sampleBuffer: sampleBuffer
            )
            frameHandler(frame)
        } catch {
            failureHandler((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        failureHandler((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

private enum MDKAudioSampleBufferError: Error, LocalizedError {
    case formatDescriptionUnavailable
    case streamDescriptionUnavailable
    case unsupportedPCMLayout(description: String)
    case audioBufferListUnavailable(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .formatDescriptionUnavailable:
            return "Audio sample buffer did not provide a format description."
        case .streamDescriptionUnavailable:
            return "Audio sample buffer did not provide a stream description."
        case .unsupportedPCMLayout(let description):
            return "Unsupported audio sample layout: \(description)"
        case .audioBufferListUnavailable(let status):
            return "Unable to access the audio sample buffer list (OSStatus \(status))."
        }
    }
}

private func MDKSystemUptimeNanoseconds() -> UInt64 {
    UInt64(max(ProcessInfo.processInfo.systemUptime, 0.0) * 1_000_000_000)
}

private func MDKMakeAudioFrame(
    sequenceNumber: UInt64,
    sampleBuffer: CMSampleBuffer
) throws -> MDKAudioFrame {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw MDKAudioSampleBufferError.formatDescriptionUnavailable
    }
    guard let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
        throw MDKAudioSampleBufferError.streamDescriptionUnavailable
    }

    let streamDescription = streamDescriptionPointer.pointee
    let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
    let frameCount = max(CMSampleBufferGetNumSamples(sampleBuffer), 0)
    let pcmFloat32LE = try MDKCopyAudioPCMFloat32InterleavedData(
        sampleBuffer: sampleBuffer,
        streamDescription: streamDescription,
        frameCount: frameCount,
        channelCount: channelCount
    )

    let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let hostTimeNanoseconds: UInt64
    if presentationTimeStamp.isValid, presentationTimeStamp.seconds.isFinite {
        hostTimeNanoseconds = UInt64(max(presentationTimeStamp.seconds, 0.0) * 1_000_000_000)
    } else {
        hostTimeNanoseconds = MDKSystemUptimeNanoseconds()
    }

    return MDKAudioFrame(
        sequenceNumber: sequenceNumber,
        hostTimeNanoseconds: hostTimeNanoseconds,
        sampleRate: Int(streamDescription.mSampleRate.rounded()),
        channelCount: channelCount,
        frameCount: frameCount,
        pcmFloat32LE: pcmFloat32LE
    )
}

private func MDKCopyAudioPCMFloat32InterleavedData(
    sampleBuffer: CMSampleBuffer,
    streamDescription: AudioStreamBasicDescription,
    frameCount: Int,
    channelCount: Int
) throws -> Data {
    let bufferCount = max(channelCount, 1)
    let bufferListSize = MemoryLayout<AudioBufferList>.size + max(bufferCount - 1, 0) * MemoryLayout<AudioBuffer>.size
    let rawBufferList = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer {
        rawBufferList.deallocate()
    }

    let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
    var retainedBlockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: bufferListSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
        blockBufferOut: &retainedBlockBuffer
    )
    guard status == noErr else {
        throw MDKAudioSampleBufferError.audioBufferListUnavailable(status: status)
    }

    let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let isFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isNonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bitsPerChannel = Int(streamDescription.mBitsPerChannel)

    let floatDataCount = frameCount * channelCount
    let outputData = NSMutableData(length: floatDataCount * MemoryLayout<Float>.size) ?? NSMutableData()
    let outputSamples = outputData.mutableBytes.bindMemory(to: Float.self, capacity: floatDataCount)

    if isFloat && bitsPerChannel == 32 {
        if !isNonInterleaved, let audioBuffer = audioBuffers.first, audioBuffer.mDataByteSize >= outputData.length {
            memcpy(outputData.mutableBytes, audioBuffer.mData, outputData.length)
            return outputData as Data
        }

        guard audioBuffers.count >= channelCount else {
            throw MDKAudioSampleBufferError.unsupportedPCMLayout(description: "Expected \(channelCount) float channels, found \(audioBuffers.count).")
        }

        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                let channelBuffer = audioBuffers[channelIndex]
                let channelSamples = channelBuffer.mData!.assumingMemoryBound(to: Float.self)
                outputSamples[(frameIndex * channelCount) + channelIndex] = channelSamples[frameIndex]
            }
        }
        return outputData as Data
    }

    if !isFloat && bitsPerChannel == 16 {
        if !isNonInterleaved, let audioBuffer = audioBuffers.first {
            let inputSamples = audioBuffer.mData!.assumingMemoryBound(to: Int16.self)
            for index in 0..<floatDataCount {
                outputSamples[index] = Float(inputSamples[index]) / Float(Int16.max)
            }
            return outputData as Data
        }

        guard audioBuffers.count >= channelCount else {
            throw MDKAudioSampleBufferError.unsupportedPCMLayout(description: "Expected \(channelCount) int16 channels, found \(audioBuffers.count).")
        }

        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                let channelBuffer = audioBuffers[channelIndex]
                let channelSamples = channelBuffer.mData!.assumingMemoryBound(to: Int16.self)
                outputSamples[(frameIndex * channelCount) + channelIndex] = Float(channelSamples[frameIndex]) / Float(Int16.max)
            }
        }
        return outputData as Data
    }

    throw MDKAudioSampleBufferError.unsupportedPCMLayout(
        description: "formatFlags=\(streamDescription.mFormatFlags) bitsPerChannel=\(bitsPerChannel)"
    )
}

private final class MDKAudioCaptureContinuationBox {
    var continuation: AsyncThrowingStream<MDKAudioFrame, Error>.Continuation?
}

private final class MDKAudioCaptureEventContinuationBox {
    var continuation: AsyncStream<MDKAudioCaptureSessionEvent>.Continuation?
}

public actor MDKAudioCaptureSession {
    public let configuration: MDKAudioCaptureConfiguration

    private let sourceFactory: MDKAudioCaptureSourceFactory

    private var runtime: (any MDKAudioCaptureSourceRuntime)?
    private var runtimeGeneration: UInt64 = 0
    private var streamToken: UInt64 = 0
    private var continuation: AsyncThrowingStream<MDKAudioFrame, Error>.Continuation?
    private var continuationToken: UInt64?
    private var nextEventContinuationToken: UInt64 = 0
    private var eventContinuations: [UInt64: AsyncStream<MDKAudioCaptureSessionEvent>.Continuation] = [:]
    private var callbacks: MDKAudioCaptureCallbacks?
    private var statistics = MDKAudioCaptureSessionStatistics()
    private var scheduledRestartTask: Task<Void, Never>?
    private var scheduledRestartGeneration: UInt64?

    public init(configuration: MDKAudioCaptureConfiguration) {
        self.configuration = configuration
        self.sourceFactory = { configuration, frameHandler, failureHandler in
            switch configuration.source {
            case .microphone:
                return MDKShimMicrophoneAudioCaptureSourceRuntime(
                    configuration: configuration,
                    frameHandler: frameHandler
                )
            case .systemOutput:
                return MDKSystemAudioCaptureSourceRuntime(
                    configuration: configuration,
                    frameHandler: frameHandler,
                    failureHandler: failureHandler
                )
            }
        }
    }

    init(
        configuration: MDKAudioCaptureConfiguration,
        sourceFactory: @escaping MDKAudioCaptureSourceFactory
    ) {
        self.configuration = configuration
        self.sourceFactory = sourceFactory
    }

    public func frames() -> AsyncThrowingStream<MDKAudioFrame, Error> {
        makeFrameStream()
    }

    public func events() -> AsyncStream<MDKAudioCaptureSessionEvent> {
        makeEventStream()
    }

    public func makeFrameStream() -> AsyncThrowingStream<MDKAudioFrame, Error> {
        if configuration.deliveryMode == .callbackOnly {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: MDKAudioCaptureSessionError.frameStreamUnsupportedInCallbackOnlyMode
                )
            }
        }

        streamToken += 1
        let token = streamToken
        let box = MDKAudioCaptureContinuationBox()
        let bufferingPolicy = configuration.backpressurePolicy.audioStreamBufferingPolicy
        let stream = AsyncThrowingStream<MDKAudioFrame, Error>(bufferingPolicy: bufferingPolicy) { continuation in
            box.continuation = continuation
        }

        guard let continuation = box.continuation else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else {
                return
            }
            Task {
                await self.clearContinuation(ifMatching: token)
            }
        }

        installContinuation(continuation, token: token)
        return stream
    }

    public func makeEventStream() -> AsyncStream<MDKAudioCaptureSessionEvent> {
        nextEventContinuationToken += 1
        let token = nextEventContinuationToken
        let box = MDKAudioCaptureEventContinuationBox()
        let stream = AsyncStream<MDKAudioCaptureSessionEvent> { continuation in
            box.continuation = continuation
        }

        guard let continuation = box.continuation else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        continuation.onTermination = { [weak self] (_: AsyncStream<MDKAudioCaptureSessionEvent>.Continuation.Termination) in
            guard let self else {
                return
            }
            Task {
                await self.removeEventContinuation(token: token)
            }
        }

        eventContinuations[token] = continuation
        return stream
    }

    public func start() async throws {
        try await start(callbacks: callbacks)
    }

    public func start(callbacks: MDKAudioCaptureCallbacks) async throws {
        try await start(callbacks: Optional(callbacks))
    }

    public func installCallbacks(_ callbacks: MDKAudioCaptureCallbacks?) {
        self.callbacks = callbacks
    }

    private func start(callbacks: MDKAudioCaptureCallbacks?) async throws {
        guard runtime == nil else {
            throw MDKAudioCaptureSessionError.alreadyRunning
        }
        if configuration.deliveryMode == .callbackOnly, callbacks == nil {
            throw MDKAudioCaptureSessionError.callbackRequiredForCallbackOnlyMode
        }

        self.callbacks = callbacks
        runtimeGeneration &+= 1
        let currentRuntimeGeneration = runtimeGeneration
        let callbackOnlyDelivery = configuration.deliveryMode == .callbackOnly && callbacks != nil

        let outputHandler: @Sendable (MDKAudioFrame) -> Void = { [weak self] frame in
            guard let self else {
                return
            }
            callbacks?.frameHandler(frame)
            if callbackOnlyDelivery {
                return
            }
            Task {
                await self.handleAudioFrame(
                    frame,
                    runtimeGeneration: currentRuntimeGeneration,
                    deliveredViaCallback: callbacks != nil
                )
            }
        }
        let failureHandler: @Sendable (String) -> Void = { [weak self] description in
            guard let self else {
                return
            }
            Task {
                await self.handleCaptureFailure(description, runtimeGeneration: currentRuntimeGeneration)
            }
        }

        let source = sourceFactory(configuration, outputHandler, failureHandler)

        do {
            try await source.start()
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            statistics = MDKAudioCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                captureFailureCount: statistics.captureFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: description,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: false
            )
            throw error
        }

        runtime = source
        statistics = MDKAudioCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            captureFailureCount: statistics.captureFailureCount,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: nil,
            isRunning: true
        )
        emitEvent(.init(kind: .started, message: "Audio capture session started."))
    }

    public func stop() async {
        await stopRuntime(finishingStream: true, stopMessage: "Audio capture session stopped.")
        await drainDeferredDeliveryWork()
    }

    public func statisticsSnapshot() -> MDKAudioCaptureSessionStatistics {
        statistics
    }

    private func installContinuation(
        _ continuation: AsyncThrowingStream<MDKAudioFrame, Error>.Continuation,
        token: UInt64
    ) {
        self.continuation?.finish()
        self.continuation = continuation
        self.continuationToken = token
    }

    private func clearContinuation(ifMatching token: UInt64) {
        guard continuationToken == token else {
            return
        }
        continuation = nil
        continuationToken = nil
        if runtime != nil, callbacks == nil {
            Task {
                await self.stopRuntime(
                    finishingStream: false,
                    stopMessage: "Audio frame consumer terminated."
                )
            }
        }
    }

    private func handleAudioFrame(
        _ frame: MDKAudioFrame,
        runtimeGeneration: UInt64,
        deliveredViaCallback: Bool
    ) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }

        var deliveredFrame = deliveredViaCallback
        guard let continuation else {
            if deliveredViaCallback {
                statistics = statisticsWith(emittedFrameDelta: 1)
            } else {
                statistics = statisticsWith(droppedFrameDelta: 1)
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Audio frame dropped because no active consumer stream exists.",
                        sourceSequenceNumber: frame.sequenceNumber
                    )
                )
            }
            return
        }

        switch continuation.yield(frame) {
        case .enqueued:
            deliveredFrame = true
            if !deliveredViaCallback {
                statistics = statisticsWith(emittedFrameDelta: 1)
            }
        case .dropped:
            if deliveredViaCallback {
                statistics = statisticsWith(emittedFrameDelta: 1)
            } else {
                statistics = statisticsWith(droppedFrameDelta: 1)
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Audio frame dropped by backpressure policy.",
                        sourceSequenceNumber: frame.sequenceNumber
                    )
                )
            }
        case .terminated:
            self.continuation = nil
            self.continuationToken = nil
            if deliveredViaCallback {
                statistics = statisticsWith(emittedFrameDelta: 1)
            } else {
                statistics = statisticsWith(droppedFrameDelta: 1)
                emitEvent(
                    .init(
                        kind: .droppedFrame,
                        message: "Audio frame stream terminated while a frame was being delivered.",
                        sourceSequenceNumber: frame.sequenceNumber
                    )
                )
                Task {
                    await self.stopRuntime(
                        finishingStream: false,
                        stopMessage: "Audio frame consumer terminated during delivery."
                    )
                }
            }
        @unknown default:
            break
        }

        if deliveredViaCallback && !deliveredFrame {
            statistics = statisticsWith(emittedFrameDelta: 1)
        }
    }

    private func handleCaptureFailure(_ description: String, runtimeGeneration: UInt64) {
        guard runtime != nil, self.runtimeGeneration == runtimeGeneration else {
            return
        }

        statistics = MDKAudioCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            captureFailureCount: statistics.captureFailureCount + 1,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: description,
            lastStopStatus: statistics.lastStopStatus,
            isRunning: statistics.isRunning
        )
        emitEvent(.init(kind: .failed, message: description))

        guard scheduledRestartTask == nil else {
            return
        }
        guard configuration.recoveryPolicy.automaticallyRestartOnFailure else {
            Task {
                await self.stopRuntime(finishingStream: false, stopMessage: description)
            }
            continuation?.finish(throwing: MDKAudioCaptureSessionError.captureFailed(description: description))
            continuation = nil
            continuationToken = nil
            return
        }
        guard statistics.automaticRestartCount < UInt64(configuration.recoveryPolicy.maximumAutomaticRestartCount) else {
            Task {
                await self.stopRuntime(finishingStream: false, stopMessage: description)
            }
            continuation?.finish(throwing: MDKAudioCaptureSessionError.restartLimitReached(lastErrorDescription: description))
            continuation = nil
            continuationToken = nil
            return
        }

        scheduledRestartGeneration = runtimeGeneration
        scheduledRestartTask = Task { [weak self] in
            guard let self else {
                return
            }
            let delayNanoseconds = UInt64(configuration.recoveryPolicy.restartDelay * 1_000_000_000)
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await self.performScheduledRestart(
                lastErrorDescription: description,
                restartGeneration: runtimeGeneration
            )
        }
    }

    private func performScheduledRestart(lastErrorDescription: String, restartGeneration: UInt64) async {
        guard runtime != nil,
              self.runtimeGeneration == restartGeneration,
              scheduledRestartGeneration == restartGeneration else {
            scheduledRestartTask = nil
            scheduledRestartGeneration = nil
            return
        }
        scheduledRestartTask = nil
        scheduledRestartGeneration = nil

        await stopRuntime(finishingStream: false, emitStopEvent: false)
        do {
            try await start()
            statistics = MDKAudioCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                captureFailureCount: statistics.captureFailureCount,
                automaticRestartCount: statistics.automaticRestartCount + 1,
                lastErrorDescription: lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: true
            )
            emitEvent(
                .init(
                    kind: .restarted,
                    message: lastErrorDescription,
                    automaticRestartCount: statistics.automaticRestartCount
                )
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            continuation?.finish(throwing: MDKAudioCaptureSessionError.restartLimitReached(lastErrorDescription: message))
            continuation = nil
            continuationToken = nil
            emitEvent(.init(kind: .failed, message: message))
        }
    }

    private func stopRuntime(
        finishingStream: Bool,
        stopMessage: String? = nil,
        emitStopEvent: Bool = true
    ) async {
        runtimeGeneration &+= 1
        scheduledRestartTask?.cancel()
        scheduledRestartTask = nil
        scheduledRestartGeneration = nil

        guard let runtime else {
            if finishingStream {
                continuation?.finish()
                continuation = nil
                continuationToken = nil
            }
            statistics = MDKAudioCaptureSessionStatistics(
                emittedFrameCount: statistics.emittedFrameCount,
                droppedFrameCount: statistics.droppedFrameCount,
                captureFailureCount: statistics.captureFailureCount,
                automaticRestartCount: statistics.automaticRestartCount,
                lastErrorDescription: statistics.lastErrorDescription,
                lastStopStatus: statistics.lastStopStatus,
                isRunning: false
            )
            if emitStopEvent {
                emitEvent(
                    .init(
                        kind: .stopped,
                        message: stopMessage ?? (finishingStream ? "Audio capture session stopped." : "Audio capture runtime stopped."),
                        stopStatus: statistics.lastStopStatus
                    )
                )
            }
            if finishingStream {
                callbacks = nil
            }
            return
        }

        let stopStatus = await runtime.stop()
        self.runtime = nil
        if finishingStream {
            continuation?.finish()
            continuation = nil
            continuationToken = nil
        }
        statistics = MDKAudioCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount,
            droppedFrameCount: statistics.droppedFrameCount,
            captureFailureCount: statistics.captureFailureCount,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: stopStatus,
            isRunning: false
        )
        if emitStopEvent {
            emitEvent(
                .init(
                    kind: .stopped,
                    message: stopMessage ?? (finishingStream ? "Audio capture session stopped." : "Audio capture runtime stopped."),
                    stopStatus: stopStatus
                )
            )
        }
        if finishingStream {
            callbacks = nil
        }
    }

    private func statisticsWith(emittedFrameDelta: UInt64 = 0, droppedFrameDelta: UInt64 = 0) -> MDKAudioCaptureSessionStatistics {
        MDKAudioCaptureSessionStatistics(
            emittedFrameCount: statistics.emittedFrameCount + emittedFrameDelta,
            droppedFrameCount: statistics.droppedFrameCount + droppedFrameDelta,
            captureFailureCount: statistics.captureFailureCount,
            automaticRestartCount: statistics.automaticRestartCount,
            lastErrorDescription: statistics.lastErrorDescription,
            lastStopStatus: statistics.lastStopStatus,
            isRunning: statistics.isRunning
        )
    }

    private func emitEvent(_ event: MDKAudioCaptureSessionEvent) {
        callbacks?.eventHandler?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(token: UInt64) {
        eventContinuations[token] = nil
    }

    private func drainDeferredDeliveryWork() async {
        for _ in 0..<3 {
            await Task.yield()
        }
    }
}

private extension MDKAudioCaptureSource {
    var debugIdentifier: String {
        switch self {
        case .microphone(let inputID):
            return "mic-\(inputID ?? "default")"
        case .systemOutput(let displayID, _):
            return "display-\(displayID)"
        }
    }
}

private extension MDKAudioCaptureBackpressurePolicy {
    var audioStreamBufferingPolicy: AsyncThrowingStream<MDKAudioFrame, Error>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded:
            return .unbounded
        case .dropOldest(let limit):
            return .bufferingOldest(max(limit, 1))
        case .dropNewest(let limit):
            return .bufferingNewest(max(limit, 1))
        }
    }
}
