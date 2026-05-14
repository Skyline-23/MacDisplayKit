import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import MetalPerformanceShaders
import VideoToolbox

public enum MDKVideoToolboxProcessingError: Error, LocalizedError, Equatable {
    case surfaceUnavailable
    case pixelBufferCreationFailed(status: CVReturn)
    case compressionSessionCreationFailed(status: OSStatus)
    case encodeFailed(status: OSStatus)
    case metalDeviceUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case blitEncoderUnavailable
    case scalerUnavailable
    case stagingPoolCreationFailed(status: CVReturn)
    case stagingBufferCreationFailed(status: CVReturn)
    case stagingSurfaceUnavailable
    case stagingTextureBindingFailed(plane: Int)
    case stagingSlotUnavailable
    case conversionRequiresMetal(sourcePixelFormat: UInt32, targetPixelFormat: UInt32)

    public var errorDescription: String? {
        switch self {
        case .surfaceUnavailable:
            return "The capture frame does not carry an IOSurface-backed surface."
        case .pixelBufferCreationFailed(let status):
            return "Unable to wrap the IOSurface in a CVPixelBuffer (CVReturn \(status))."
        case .compressionSessionCreationFailed(let status):
            return "Unable to create a VTCompressionSession (OSStatus \(status))."
        case .encodeFailed(let status):
            return "VTCompressionSessionEncodeFrame failed (OSStatus \(status))."
        case .metalDeviceUnavailable:
            return "A Metal device is not available for staged encoder copies."
        case .commandQueueUnavailable:
            return "A Metal command queue is not available for staged encoder copies."
        case .commandBufferUnavailable:
            return "Unable to create a Metal command buffer for the staged encoder copy."
        case .blitEncoderUnavailable:
            return "Unable to create a Metal blit encoder for the staged encoder copy."
        case .scalerUnavailable:
            return "A Metal scaler is not available for staged encoder downscaling."
        case .stagingPoolCreationFailed(let status):
            return "Unable to create a staged CVPixelBufferPool (CVReturn \(status))."
        case .stagingBufferCreationFailed(let status):
            return "Unable to allocate a staged CVPixelBuffer from the pool (CVReturn \(status))."
        case .stagingSurfaceUnavailable:
            return "The staged CVPixelBuffer did not expose an IOSurface."
        case .stagingTextureBindingFailed(let plane):
            return "Unable to bind staged plane \(plane) into a Metal texture."
        case .stagingSlotUnavailable:
            return "No staged encoder slot is currently available."
        case .conversionRequiresMetal(let sourcePixelFormat, let targetPixelFormat):
            return String(
                format: "Converting source pixel format 0x%08X into encoder input 0x%08X requires Metal staging.",
                sourcePixelFormat,
                targetPixelFormat
            )
        }
    }
}

private final class MDKVideoToolboxSubmissionToken {
    let slotIdentifier: Int?
    let submittedAt: TimeInterval
    let sourceSequenceNumber: UInt64
    let sourceDisplayTime: UInt64
    private let releasePendingFrame: @Sendable () -> Void

    init(
        slotIdentifier: Int?,
        submittedAt: TimeInterval,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        releasePendingFrame: @escaping @Sendable () -> Void
    ) {
        self.slotIdentifier = slotIdentifier
        self.submittedAt = submittedAt
        self.sourceSequenceNumber = sourceSequenceNumber
        self.sourceDisplayTime = sourceDisplayTime
        self.releasePendingFrame = releasePendingFrame
    }

    func markCompleted() {
        releasePendingFrame()
    }
}

private final class MDKVideoToolboxSendablePixelBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

private struct MDKVideoToolboxTimingAccumulator {
    var sampleCount: UInt64 = 0
    var totalMilliseconds: Double = 0
    var maxMilliseconds: Double = 0

    mutating func record(_ milliseconds: Double) {
        let boundedMilliseconds = max(milliseconds, 0)
        sampleCount += 1
        totalMilliseconds += boundedMilliseconds
        maxMilliseconds = max(maxMilliseconds, boundedMilliseconds)
    }

    var averageMilliseconds: Double {
        guard sampleCount > 0 else {
            return 0
        }
        return totalMilliseconds / Double(sampleCount)
    }
}

private enum MDKVideoToolboxTimingMetric {
    case encodeQueueWait
    case encodeInvocation
    case metalStage
    case vtEncodeCall
}

enum MDKVideoToolboxLatencyPolicy {
    static func maxFrameDelayCount(
        codec: MDKVideoEncoderCodec,
        targetFrameRate: Int
    ) -> Int {
        if codec == .proResProxy {
            return 0
        }

        switch codec {
        case .h264:
            return 2
        case .hevc:
            return 1
        case .proResProxy:
            return 0
        }
    }
}

private struct MDKVideoToolboxReplayState {
    let imageBuffer: MDKVideoToolboxSendablePixelBuffer
    let frame: MDKCaptureFrame
}

private struct MDKVideoToolboxStagingSlot {
    let identifier: Int
    let pixelBuffer: CVPixelBuffer
    let surface: MDKCaptureSurface
    let textures: [MTLTexture]
}

private struct MDKVideoToolboxSourceTextureCacheEntry {
    let descriptors: [MDKMetalPlaneDescriptor]
    let textures: [MTLTexture]
}

private final class MDKMetalBilinearScaler {
    private let scaler: MPSImageBilinearScale

    init(device: any MTLDevice) {
        self.scaler = MPSImageBilinearScale(device: device)
    }

    func encode(
        commandBuffer: any MTLCommandBuffer,
        sourceTextures: [MTLTexture],
        destinationTextures: [MTLTexture]
    ) {
        for (sourceTexture, destinationTexture) in zip(sourceTextures, destinationTextures) {
            scaler.encode(
                commandBuffer: commandBuffer,
                sourceTexture: sourceTexture,
                destinationTexture: destinationTexture
            )
        }
    }
}

private let MDKVideoToolboxOutputCallback: VTCompressionOutputCallback = { outputCallbackRefCon, sourceFrameRefCon, status, _, sampleBuffer in
    guard let outputCallbackRefCon else {
        if let sourceFrameRefCon {
            Unmanaged<MDKVideoToolboxSubmissionToken>.fromOpaque(sourceFrameRefCon).release()
        }
        return
    }

    let processor = Unmanaged<MDKVideoToolboxEncodingProcessor>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    let token = sourceFrameRefCon.map {
        Unmanaged<MDKVideoToolboxSubmissionToken>.fromOpaque($0).takeRetainedValue()
    }
    let callbackReceivedAt = ProcessInfo.processInfo.systemUptime
    processor.recordOutputCallback(
        status: status,
        sampleBuffer: sampleBuffer,
        submissionToken: token,
        callbackReceivedAt: callbackReceivedAt
    )
}

public final class MDKVideoToolboxEncodingProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    public let codec: MDKVideoEncoderCodec
    public let preprocessStrategy: MDKVideoPreprocessStrategy
    public let targetFrameRate: Int
    public let encoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy
    private let device: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private let scaler: MDKMetalBilinearScaler?
    private let colorConverter: MDKMetalBGRAToYCbCrConverter?
    private let maxInflightStagingSlots: Int
    private let outputHandler: (@Sendable (MDKEncodedFrame) -> Void)?
    private let failureHandler: (@Sendable (String) -> Void)?
    private let hdrConfiguration: MDKVideoHDRConfiguration?
    private let targetAverageBitRateBitsPerSecond: Int?
    private let tileMetadata: MDKEncodedFrameTileMetadata
    private let sourceRegion: CGRect?

    private var compressionSession: VTCompressionSession?
    private var activeDimensions: SIMD2<Int>?
    private var activePixelFormat: UInt32?
    private var pixelBufferAttributes: CFDictionary?
    private var encoderPixelBufferAttributes: CFDictionary?
    private var pixelBufferCache: [UInt32: CVPixelBuffer] = [:]
    private var sourceTextureCache: [UInt32: MDKVideoToolboxSourceTextureCacheEntry] = [:]
    private var stagingPixelBufferPool: CVPixelBufferPool?
    private var stagingSlots: [Int: MDKVideoToolboxStagingSlot] = [:]
    private var availableStagingSlotIdentifiers: [Int] = []
    private var nextStagingSlotIdentifier: Int = 0
    private var frameIndex: Int64 = 0
    private var processedFrameCount: UInt64 = 0
    private var processingFailureCount: UInt64 = 0
    private var processingErrorHistogram: [String: Int] = [:]
    private let outputQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.output")
    private var outputCallbackCount: UInt64 = 0
    private var completedOutputFrameCount: UInt64 = 0
    private var outputCallbackStatusHistogram: [String: Int] = [:]
    private var outputCallbackLatencyHistogram: [String: Int] = [:]
    private var minOutputCallbackLatencyMilliseconds: Double?
    private var maxOutputCallbackLatencyMilliseconds: Double?
    private var submittedFrameCount: UInt64 = 0
    private var usingHardwareAcceleratedEncoder: Bool?
    private var encoderPixelBufferPoolIsShared: Bool?
    private var recommendedParallelizationLimit: Int?
    private var sessionConfigurationNotes: [String] = []
    private var directSubmissionFrameCount: UInt64 = 0
    private var stagedSubmissionFrameCount: UInt64 = 0
    private let colorConverterInitializationErrorDescription: String?
    private let outputDrainGroup = DispatchGroup()
    private let stagingSubmissionGroup = DispatchGroup()
    private let encodeQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.encode")
    private let submissionQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.submit")
    private let encodeQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let encodeQueueSpecificValue: UInt8 = 1
    private var forceNextKeyFrame = false
    private var lastFreshReplayState: MDKVideoToolboxReplayState?
    private var lastImmediateRecoveryReplayDisplayTime: UInt64?
    private var immediateReplaySubmissionCount: UInt64 = 0
    private var suppressedImmediateReplayCount: UInt64 = 0
    private var encodeQueueWaitTiming = MDKVideoToolboxTimingAccumulator()
    private var encodeInvocationTiming = MDKVideoToolboxTimingAccumulator()
    private var metalStageTiming = MDKVideoToolboxTimingAccumulator()
    private var vtEncodeCallTiming = MDKVideoToolboxTimingAccumulator()

    public init(
        codec: MDKVideoEncoderCodec = .hevc,
        preprocessStrategy: MDKVideoPreprocessStrategy = .none,
        targetFrameRate: Int = 120,
        encoderInputStrategy: MDKEncodedCaptureEncoderInputStrategy = .auto,
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        maxInflightStagingSlots: Int = 128,
        outputHandler: (@Sendable (MDKEncodedFrame) -> Void)? = nil,
        failureHandler: (@Sendable (String) -> Void)? = nil,
        hdrConfiguration: MDKVideoHDRConfiguration? = nil,
        targetAverageBitRateBitsPerSecond: Int? = nil,
        tileMetadata: MDKEncodedFrameTileMetadata = .singleFrame,
        sourceRegion: CGRect? = nil
    ) {
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.targetFrameRate = max(targetFrameRate, 1)
        self.encoderInputStrategy = encoderInputStrategy
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.scaler = device.map { MDKMetalBilinearScaler(device: $0) }
        if let device {
            do {
                self.colorConverter = try MDKMetalBGRAToYCbCrConverter(device: device)
                self.colorConverterInitializationErrorDescription = nil
            } catch {
                self.colorConverter = nil
                self.colorConverterInitializationErrorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        } else {
            self.colorConverter = nil
            self.colorConverterInitializationErrorDescription = "Metal device unavailable."
        }
        self.maxInflightStagingSlots = max(maxInflightStagingSlots, 1)
        self.outputHandler = outputHandler
        self.failureHandler = failureHandler
        self.hdrConfiguration = hdrConfiguration?.negotiatedForEncodedDelivery(codec: codec)
        self.targetAverageBitRateBitsPerSecond = targetAverageBitRateBitsPerSecond.flatMap { $0 > 0 ? $0 : nil }
        self.tileMetadata = tileMetadata
        self.sourceRegion = sourceRegion
        self.encodeQueue.setSpecific(key: encodeQueueSpecificKey, value: encodeQueueSpecificValue)
    }

    deinit {
        if DispatchQueue.getSpecific(key: encodeQueueSpecificKey) == encodeQueueSpecificValue {
            invalidateSession()
        } else {
            encodeQueue.sync {
                invalidateSession()
            }
        }
    }

    public func process(frame: MDKCaptureFrame) throws {
        try process(frame: frame, releaseSourceFrame: {})
    }

    public func requestImmediateKeyFrame() {
        if DispatchQueue.getSpecific(key: encodeQueueSpecificKey) == encodeQueueSpecificValue {
            forceNextKeyFrame = true
            replayLastSubmittedFrameAsKeyFrameIfPossible()
        } else {
            encodeQueue.async { [self] in
                forceNextKeyFrame = true
                replayLastSubmittedFrameAsKeyFrameIfPossible()
            }
        }
    }

    public func process(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
        let processRequestedAt = ProcessInfo.processInfo.systemUptime
        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let retainedFrame = MDKCaptureFrame(
            sequenceNumber: frame.sequenceNumber,
            displayTime: frame.displayTime,
            surfaceID: frame.surfaceID,
            width: frame.width,
            height: frame.height,
            pixelFormat: frame.pixelFormat,
            surface: surface,
            origin: frame.origin,
            cursorOverlaySample: frame.cursorOverlaySample,
            sourceCaptureDurationNanoseconds: frame.sourceCaptureDurationNanoseconds,
            sourceCursorCompositeDurationNanoseconds: frame.sourceCursorCompositeDurationNanoseconds
        )
        let submitFrame = { [self, retainedFrame] in
            let encodeStartedAt = ProcessInfo.processInfo.systemUptime
            recordTiming(.encodeQueueWait, startedAt: processRequestedAt, endedAt: encodeStartedAt)
            do {
                try encode(
                    frame: retainedFrame,
                    releaseSourceFrame: releaseSourceFrame
                )
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                processingFailureCount += 1
                processingErrorHistogram[errorDescription, default: 0] += 1
                failureHandler?(errorDescription)
            }
            recordTiming(.encodeInvocation, startedAt: encodeStartedAt)
        }

        if DispatchQueue.getSpecific(key: encodeQueueSpecificKey) == encodeQueueSpecificValue {
            submitFrame()
        } else {
            encodeQueue.sync(execute: submitFrame)
        }
    }

    func finalize() -> MDKCaptureFrameProcessingSummary? {
        encodeQueue.sync {}
        let stagingSubmissionWaitStatus = stagingSubmissionGroup.wait(timeout: .now() + 1.5)
        return encodeQueue.sync { [self] in
            submissionQueue.sync {}
            if let compressionSession {
                VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            }
            let outputDrainWaitStatus = outputDrainGroup.wait(timeout: .now() + 1.5)
            let outputSummary = outputQueue.sync {
                (
                    processedFrameCount,
                    processingFailureCount,
                    processingErrorHistogram,
                    submittedFrameCount,
                    outputCallbackCount,
                    completedOutputFrameCount,
                    outputCallbackStatusHistogram,
                    outputCallbackLatencyHistogram,
                    minOutputCallbackLatencyMilliseconds,
                    maxOutputCallbackLatencyMilliseconds,
                    directSubmissionFrameCount,
                    stagedSubmissionFrameCount
                )
            }
            return MDKCaptureFrameProcessingSummary(
                processedFrameCount: outputSummary.0,
                processingFailureCount: outputSummary.1,
                processingErrorHistogram: outputSummary.2,
                outputCallbackCount: outputSummary.4,
                completedOutputFrameCount: outputSummary.5,
                outputCallbackStatusHistogram: outputSummary.6,
                outputCallbackLatencyHistogram: outputSummary.7,
                minOutputCallbackLatencyMilliseconds: outputSummary.8,
                maxOutputCallbackLatencyMilliseconds: outputSummary.9,
                notes: runtimeNotes(
                    submittedFrameCount: outputSummary.3,
                    directSubmissionFrameCount: outputSummary.10,
                    stagedSubmissionFrameCount: outputSummary.11,
                    includeDrainWaitStatus: true,
                    stagingSubmissionWaitStatus: stagingSubmissionWaitStatus,
                    outputDrainWaitStatus: outputDrainWaitStatus
                )
            )
        }
    }

    func liveSummary() -> MDKCaptureFrameProcessingSummary? {
        encodeQueue.sync {}
        return outputQueue.sync {
            MDKCaptureFrameProcessingSummary(
                processedFrameCount: processedFrameCount,
                processingFailureCount: processingFailureCount,
                processingErrorHistogram: processingErrorHistogram,
                outputCallbackCount: outputCallbackCount,
                completedOutputFrameCount: completedOutputFrameCount,
                outputCallbackStatusHistogram: outputCallbackStatusHistogram,
                outputCallbackLatencyHistogram: outputCallbackLatencyHistogram,
                minOutputCallbackLatencyMilliseconds: minOutputCallbackLatencyMilliseconds,
                maxOutputCallbackLatencyMilliseconds: maxOutputCallbackLatencyMilliseconds,
                notes: runtimeNotes(
                    submittedFrameCount: submittedFrameCount,
                    directSubmissionFrameCount: directSubmissionFrameCount,
                    stagedSubmissionFrameCount: stagedSubmissionFrameCount,
                    includeDrainWaitStatus: false,
                    stagingSubmissionWaitStatus: nil,
                    outputDrainWaitStatus: nil
                )
            )
        }
    }

    private func runtimeNotes(
        submittedFrameCount: UInt64,
        directSubmissionFrameCount: UInt64,
        stagedSubmissionFrameCount: UInt64,
        includeDrainWaitStatus: Bool,
        stagingSubmissionWaitStatus: DispatchTimeoutResult?,
        outputDrainWaitStatus: DispatchTimeoutResult?
    ) -> [String] {
        var notes = [
            "videoToolboxSubmitMode=sync-submit-queue",
            "videoToolboxOutputCallback=non-nil",
            "videoToolboxCodec=\(codec.rawValue)",
            "videoToolboxPreprocessStrategy=\(preprocessStrategy.rawValue)",
            "videoToolboxStagingMode=\(commandQueue == nil ? "direct-iosurface" : "hybrid-direct-or-metal-staging")",
            "videoToolboxStagedSourceReleaseMode=post-submit",
            "videoToolboxDirectSubmissionFrameCount=\(directSubmissionFrameCount)",
            "videoToolboxStagedSubmissionFrameCount=\(stagedSubmissionFrameCount)",
            "videoToolboxColorConversionMode=\(sessionConfigurationNotes.contains(where: { $0.hasPrefix("videoToolboxColorConversion=") }) ? "custom" : "passthrough")",
            "videoToolboxMaxInflightStagingSlots=\(maxInflightStagingSlots)",
            "videoToolboxSubmittedFrameCount=\(submittedFrameCount)",
            "videoToolboxImmediateReplaySubmissionCount=\(immediateReplaySubmissionCount)",
            "videoToolboxSuppressedImmediateReplayCount=\(suppressedImmediateReplayCount)",
            "videoToolboxUsingHardwareEncoder=\(describeHardwareAcceleration(usingHardwareAcceleratedEncoder))",
            "videoToolboxPixelBufferPoolIsShared=\(describeHardwareAcceleration(encoderPixelBufferPoolIsShared))",
            "videoToolboxRecommendedParallelizationLimit=\(recommendedParallelizationLimit.map(String.init) ?? "unknown")",
            "videoToolboxPixelBufferCacheSize=\(pixelBufferCache.count)",
            "videoToolboxEncodeQueueWaitSampleCount=\(encodeQueueWaitTiming.sampleCount)",
            "videoToolboxEncodeQueueWaitAverageMilliseconds=\(formatMilliseconds(encodeQueueWaitTiming.averageMilliseconds))",
            "videoToolboxEncodeQueueWaitMaxMilliseconds=\(formatMilliseconds(encodeQueueWaitTiming.maxMilliseconds))",
            "videoToolboxEncodeInvocationSampleCount=\(encodeInvocationTiming.sampleCount)",
            "videoToolboxEncodeInvocationAverageMilliseconds=\(formatMilliseconds(encodeInvocationTiming.averageMilliseconds))",
            "videoToolboxEncodeInvocationMaxMilliseconds=\(formatMilliseconds(encodeInvocationTiming.maxMilliseconds))",
            "videoToolboxMetalStageSampleCount=\(metalStageTiming.sampleCount)",
            "videoToolboxMetalStageAverageMilliseconds=\(formatMilliseconds(metalStageTiming.averageMilliseconds))",
            "videoToolboxMetalStageMaxMilliseconds=\(formatMilliseconds(metalStageTiming.maxMilliseconds))",
            "videoToolboxVTEncodeCallSampleCount=\(vtEncodeCallTiming.sampleCount)",
            "videoToolboxVTEncodeCallAverageMilliseconds=\(formatMilliseconds(vtEncodeCallTiming.averageMilliseconds))",
            "videoToolboxVTEncodeCallMaxMilliseconds=\(formatMilliseconds(vtEncodeCallTiming.maxMilliseconds))"
        ]
        if includeDrainWaitStatus {
            notes.append("videoToolboxStagingSubmissionWait=\(stagingSubmissionWaitStatus == .success ? "success" : "timeout")")
            notes.append("videoToolboxOutputDrainWait=\(outputDrainWaitStatus == .success ? "success" : "timeout")")
        }
        notes += colorConverterInitializationErrorDescription.map { ["videoToolboxColorConverterInitError=\($0)"] } ?? []
        notes += sessionConfigurationNotes
        return notes
    }

    private func encode(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
        if !sessionConfigurationNotes.contains(where: { $0.hasPrefix("videoToolboxSourcePixelFormat=") }) {
            sessionConfigurationNotes.append(
                String(format: "videoToolboxSourcePixelFormat=0x%08X", frame.pixelFormat)
            )
        }
        if let hdrConfiguration {
            if !sessionConfigurationNotes.contains(where: { $0.hasPrefix("videoToolboxSourceColorPrimaries=") }) {
                sessionConfigurationNotes.append(
                    "videoToolboxSourceColorPrimaries=\((hdrConfiguration.sourceColorPrimaries ?? hdrConfiguration.colorPrimaries).rawValue)"
                )
            }
            if !sessionConfigurationNotes.contains(where: { $0.hasPrefix("videoToolboxSignalColorPrimaries=") }) {
                sessionConfigurationNotes.append(
                    "videoToolboxSignalColorPrimaries=\(hdrConfiguration.colorPrimaries.rawValue)"
                )
            }
        }
        let targetPixelFormat = codec.preferredInputPixelFormat(
            for: frame.pixelFormat,
            hdrConfiguration: hdrConfiguration,
            strategy: encoderInputStrategy
        )
        let region = effectiveSourceRegion(for: frame)
        let processingWidth = max(Int(region.width.rounded(.down)), 1)
        let processingHeight = max(Int(region.height.rounded(.down)), 1)
        let outputDimensions = preprocessStrategy.outputDimensions(
            sourceWidth: processingWidth,
            sourceHeight: processingHeight,
            pixelFormat: targetPixelFormat
        )
        try ensureCompressionSession(
            width: outputDimensions.x,
            height: outputDimensions.y,
            pixelFormat: targetPixelFormat
        )

        let needsPixelFormatConversion = frame.pixelFormat != targetPixelFormat
        let needsScaling = outputDimensions.x != processingWidth || outputDimensions.y != processingHeight

        let hasCursorOverlay = frame.cursorOverlaySample != nil
        let requiresDetachedSubmissionSurface = shouldUseDetachedSubmissionSurface(
            sourcePixelFormat: frame.pixelFormat,
            targetPixelFormat: targetPixelFormat,
            needsScaling: needsScaling,
            hasCursorOverlay: hasCursorOverlay
        )

        if let commandQueue, requiresDetachedSubmissionSurface {
            try stageAndEncode(
                frame: frame,
                targetPixelFormat: targetPixelFormat,
                commandQueue: commandQueue,
                releaseSourceFrame: releaseSourceFrame
            )
        } else {
            guard !needsPixelFormatConversion && !needsScaling else {
                throw MDKVideoToolboxProcessingError.conversionRequiresMetal(
                    sourcePixelFormat: frame.pixelFormat,
                    targetPixelFormat: targetPixelFormat
                )
            }
            try encodeDirect(
                frame: frame,
                releaseSourceFrame: releaseSourceFrame
            )
        }
    }

    func shouldUseDetachedSubmissionSurface(
        sourcePixelFormat: UInt32,
        targetPixelFormat: UInt32,
        needsScaling: Bool,
        hasCursorOverlay: Bool
    ) -> Bool {
        if codec.requiresDetachedSubmissionSurface(
            sourcePixelFormat: sourcePixelFormat,
            targetPixelFormat: targetPixelFormat,
            needsScaling: needsScaling,
            hasCursorOverlay: hasCursorOverlay
        ) {
            return true
        }

        guard !needsScaling,
              !hasCursorOverlay,
              sourcePixelFormat == targetPixelFormat,
              commandQueue != nil else {
            return false
        }

        switch sourcePixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private func encodeDirect(
        frame: MDKCaptureFrame,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let imageBuffer = try wrappedPixelBuffer(for: frame, surface: surface)
        try submitToEncoder(
            imageBuffer: imageBuffer,
            frame: frame,
            slotIdentifier: nil,
            releasePendingFrame: {}
        )
        releaseSourceFrame()
        recordProcessingSuccess(isStaged: false)
    }

    private func stageAndEncode(
        frame: MDKCaptureFrame,
        targetPixelFormat: UInt32,
        commandQueue: any MTLCommandQueue,
        releaseSourceFrame: @escaping @Sendable () -> Void
    ) throws {
        guard let device else {
            throw MDKVideoToolboxProcessingError.metalDeviceUnavailable
        }
        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let sourceTextures = try makeSourceTextures(
            for: frame,
            surface: surface,
            device: device
        )
        let cursorTexture = try makeCursorTexture(
            for: frame.cursorOverlaySample,
            device: device
        )
        let outputDimensions = preprocessStrategy.outputDimensions(
            sourceWidth: max(Int(effectiveSourceRegion(for: frame).width.rounded(.down)), 1),
            sourceHeight: max(Int(effectiveSourceRegion(for: frame).height.rounded(.down)), 1),
            pixelFormat: targetPixelFormat
        )
        let slot = try acquireStagingSlot(
            width: outputDimensions.x,
            height: outputDimensions.y,
            pixelFormat: targetPixelFormat,
            device: device
        )
        let slotIdentifier = slot.identifier
        let stagedPixelBuffer = MDKVideoToolboxSendablePixelBuffer(pixelBuffer: slot.pixelBuffer)
        let metalStageStartedAt = ProcessInfo.processInfo.systemUptime

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            releaseStagingSlot(identifier: slotIdentifier)
            throw MDKVideoToolboxProcessingError.commandBufferUnavailable
        }
        let presentationTimeStamp = CMTime(value: frameIndex, timescale: Int32(targetFrameRate))
        frameIndex += 1
        stagingSubmissionGroup.enter()

        if frame.pixelFormat != targetPixelFormat {
            guard let colorConverter else {
                stagingSubmissionGroup.leave()
                releaseStagingSlot(identifier: slotIdentifier)
                throw MDKVideoToolboxProcessingError.conversionRequiresMetal(
                    sourcePixelFormat: frame.pixelFormat,
                    targetPixelFormat: targetPixelFormat
                )
            }
            if !sessionConfigurationNotes.contains(where: { $0.hasPrefix("videoToolboxColorConversion=") }) {
                sessionConfigurationNotes.append(
                    String(
                        format: "videoToolboxColorConversion=0x%08X->0x%08X",
                        frame.pixelFormat,
                        targetPixelFormat
                    )
                )
            }
            try colorConverter.encode(
                commandBuffer: commandBuffer,
                sourceTextures: sourceTextures,
                destinationTextures: slot.textures,
                destinationPixelFormat: targetPixelFormat,
                sourceRegion: effectiveSourceRegion(for: frame),
                hdrConfiguration: hdrConfiguration,
                cursorTexture: cursorTexture,
                cursorOverlaySample: frame.cursorOverlaySample
            )
        } else if requiresScaling(sourceTextures: sourceTextures, destinationTextures: slot.textures) {
            guard let scaler else {
                stagingSubmissionGroup.leave()
                releaseStagingSlot(identifier: slotIdentifier)
                throw MDKVideoToolboxProcessingError.scalerUnavailable
            }
            scaler.encode(
                commandBuffer: commandBuffer,
                sourceTextures: sourceTextures,
                destinationTextures: slot.textures
            )
            if let cursorOverlaySample = scaledCursorOverlaySample(
                from: frame.cursorOverlaySample,
                sourceWidth: frame.width,
                sourceHeight: frame.height,
                destinationWidth: outputDimensions.x,
                destinationHeight: outputDimensions.y
            ), let cursorTexture {
                guard let colorConverter else {
                    stagingSubmissionGroup.leave()
                    releaseStagingSlot(identifier: slotIdentifier)
                    throw MDKVideoToolboxProcessingError.conversionRequiresMetal(
                        sourcePixelFormat: frame.pixelFormat,
                        targetPixelFormat: targetPixelFormat
                    )
                }
                try colorConverter.overlayCursorOnBGRA(
                    commandBuffer: commandBuffer,
                    destinationTexture: slot.textures[0],
                    cursorTexture: cursorTexture,
                    cursorRect: cursorOverlaySample.rect,
                    cursorVerticallyFlipped: cursorOverlaySample.isVerticallyFlipped
                )
            }
        } else {
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                stagingSubmissionGroup.leave()
                releaseStagingSlot(identifier: slotIdentifier)
                throw MDKVideoToolboxProcessingError.blitEncoderUnavailable
            }

            for (sourceTexture, destinationTexture) in zip(sourceTextures, slot.textures) {
                let sourceRegion = effectiveSourceRegion(for: frame)
                let copyWidth = min(
                    destinationTexture.width,
                    max(Int(sourceRegion.width.rounded(.down)), 1)
                )
                let copyHeight = min(
                    destinationTexture.height,
                    max(Int(sourceRegion.height.rounded(.down)), 1)
                )
                let copySize = MTLSize(width: copyWidth, height: copyHeight, depth: 1)
                blitEncoder.copy(
                    from: sourceTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(
                        x: max(Int(sourceRegion.minX.rounded(.down)), 0),
                        y: max(Int(sourceRegion.minY.rounded(.down)), 0),
                        z: 0
                    ),
                    sourceSize: copySize,
                    to: destinationTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blitEncoder.endEncoding()
            if let cursorOverlaySample = frame.cursorOverlaySample,
               let cursorTexture {
                guard let colorConverter else {
                    stagingSubmissionGroup.leave()
                    releaseStagingSlot(identifier: slotIdentifier)
                    throw MDKVideoToolboxProcessingError.conversionRequiresMetal(
                        sourcePixelFormat: frame.pixelFormat,
                        targetPixelFormat: targetPixelFormat
                    )
                }
                try colorConverter.overlayCursorOnBGRA(
                    commandBuffer: commandBuffer,
                    destinationTexture: slot.textures[0],
                    cursorTexture: cursorTexture,
                    cursorRect: cursorOverlaySample.rect,
                    cursorVerticallyFlipped: cursorOverlaySample.isVerticallyFlipped
                )
            }
        }
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            guard let self else {
                releaseSourceFrame()
                return
            }
            let commandBufferStatus = commandBuffer.status
            guard commandBufferStatus == .completed else {
                releaseSourceFrame()
                self.recordProcessingFailure("Metal staged copy failed (\(commandBufferStatus.rawValue)).")
                self.releaseStagingSlot(identifier: slotIdentifier)
                self.failureHandler?("Metal staged copy failed (\(commandBufferStatus.rawValue)).")
                self.stagingSubmissionGroup.leave()
                return
            }
            self.recordTiming(.metalStage, startedAt: metalStageStartedAt)
            self.submissionQueue.async { [self] in
                do {
                    try submitToEncoder(
                        imageBuffer: stagedPixelBuffer.pixelBuffer,
                        frame: frame,
                        slotIdentifier: slotIdentifier,
                        presentationTimeStamp: presentationTimeStamp,
                        releasePendingFrame: {}
                    )
                    releaseSourceFrame()
                    recordProcessingSuccess(isStaged: true)
                } catch {
                    releaseSourceFrame()
                    let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    recordProcessingFailure(errorDescription)
                    releaseStagingSlot(identifier: slotIdentifier)
                    failureHandler?(errorDescription)
                }
                stagingSubmissionGroup.leave()
            }
        }
        commandBuffer.commit()
    }

    private func effectiveSourceRegion(for frame: MDKCaptureFrame) -> CGRect {
        let fullFrame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard let sourceRegion else {
            return fullFrame
        }
        let boundedRegion = sourceRegion.intersection(fullFrame)
        return boundedRegion.isNull || boundedRegion.isEmpty ? fullFrame : boundedRegion
    }

    private func submitToEncoder(
        imageBuffer: CVPixelBuffer,
        frame: MDKCaptureFrame,
        slotIdentifier: Int?,
        presentationTimeStamp: CMTime? = nil,
        releasePendingFrame: @escaping @Sendable () -> Void = {}
    ) throws {
        guard let compressionSession else {
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: OSStatus(unimpErr))
        }

        hdrConfiguration?.apply(to: imageBuffer)

        let resolvedPresentationTimeStamp = presentationTimeStamp ?? {
            let timestamp = CMTime(value: frameIndex, timescale: Int32(targetFrameRate))
            frameIndex += 1
            return timestamp
        }()
        let submissionToken = Unmanaged.passRetained(
            MDKVideoToolboxSubmissionToken(
                slotIdentifier: slotIdentifier,
                submittedAt: ProcessInfo.processInfo.systemUptime,
                sourceSequenceNumber: frame.sequenceNumber,
                sourceDisplayTime: frame.displayTime,
                releasePendingFrame: releasePendingFrame
            )
        )

        outputDrainGroup.enter()

        let vtEncodeCallStartedAt = ProcessInfo.processInfo.systemUptime
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: resolvedPresentationTimeStamp,
            duration: .invalid,
            frameProperties: makeFrameProperties(forceKeyFrame: consumeImmediateKeyFrameRequest()),
            sourceFrameRefcon: submissionToken.toOpaque(),
            infoFlagsOut: nil
        )
        recordTiming(.vtEncodeCall, startedAt: vtEncodeCallStartedAt)
        guard status == noErr else {
            outputDrainGroup.leave()
            submissionToken.release()
            releasePendingFrame()
            throw MDKVideoToolboxProcessingError.encodeFailed(status: status)
        }
        if frame.origin == .fresh {
            lastFreshReplayState = MDKVideoToolboxReplayState(
                imageBuffer: MDKVideoToolboxSendablePixelBuffer(pixelBuffer: imageBuffer),
                frame: frame
            )
        }
        outputQueue.sync {
            submittedFrameCount += 1
        }
    }

    private func replayLastSubmittedFrameAsKeyFrameIfPossible() {
        guard let lastFreshReplayState,
              compressionSession != nil else {
            return
        }

        if shouldSuppressImmediateReplayForPendingFrames() {
            suppressedImmediateReplayCount += 1
            return
        }

        let previousFrame = lastFreshReplayState.frame
        if lastImmediateRecoveryReplayDisplayTime == previousFrame.displayTime {
            suppressedImmediateReplayCount += 1
            return
        }
        let syntheticDisplayTime = max(mach_absolute_time(), previousFrame.displayTime &+ 1)
        let replayFrame = MDKCaptureFrame(
            sequenceNumber: previousFrame.sequenceNumber &+ 1,
            displayTime: syntheticDisplayTime,
            surfaceID: previousFrame.surfaceID,
            width: previousFrame.width,
            height: previousFrame.height,
            pixelFormat: previousFrame.pixelFormat,
            surface: previousFrame.surface,
            origin: .recoveryReplay,
            cursorOverlaySample: previousFrame.cursorOverlaySample,
            sourceCaptureDurationNanoseconds: previousFrame.sourceCaptureDurationNanoseconds,
            sourceCursorCompositeDurationNanoseconds: previousFrame.sourceCursorCompositeDurationNanoseconds
        )

        do {
            try submitToEncoder(
                imageBuffer: lastFreshReplayState.imageBuffer.pixelBuffer,
                frame: replayFrame,
                slotIdentifier: nil,
                releasePendingFrame: {}
            )
            lastImmediateRecoveryReplayDisplayTime = previousFrame.displayTime
            immediateReplaySubmissionCount += 1
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            recordProcessingFailure(errorDescription)
            failureHandler?(errorDescription)
        }
    }

    private func shouldSuppressImmediateReplayForPendingFrames() -> Bool {
        guard codec == .hevc,
              hdrConfiguration?.transferFunction == .smpteSt2084PQ,
              let compressionSession else {
            return false
        }

        guard let pendingFrames = copyIntegerSessionProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_NumberOfPendingFrames
        ) else {
            return false
        }

        return pendingFrames > 0
    }

    private func consumeImmediateKeyFrameRequest() -> Bool {
        if DispatchQueue.getSpecific(key: encodeQueueSpecificKey) != encodeQueueSpecificValue {
            return encodeQueue.sync {
                consumeImmediateKeyFrameRequest()
            }
        }

        let shouldForceKeyFrame = forceNextKeyFrame
        forceNextKeyFrame = false
        return shouldForceKeyFrame
    }

    private func makeFrameProperties(forceKeyFrame: Bool) -> CFDictionary? {
        guard forceKeyFrame else {
            return nil
        }

        return [
            kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
        ] as CFDictionary
    }

    private func ensureCompressionSession(
        width: Int,
        height: Int,
        pixelFormat: UInt32
    ) throws {
        if let activeDimensions,
           activePixelFormat == pixelFormat,
           activeDimensions == SIMD2(width, height),
           compressionSession != nil {
            return
        }

        invalidateSession()

        let sourceImageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        pixelBufferAttributes = sourceImageAttributes as CFDictionary
        sessionConfigurationNotes.removeAll(keepingCapacity: true)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.codecType,
            encoderSpecification: makeEncoderSpecification(),
            imageBufferAttributes: sourceImageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: MDKVideoToolboxOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: status)
        }

        let isHighRefreshLowLatency = codec != .proResProxy
        let isHighRefreshHDRHEVC =
            codec == .hevc &&
            isHighRefreshLowLatency &&
            hdrConfiguration?.transferFunction == .smpteSt2084PQ
        let allowsTemporalCompression = codec != .proResProxy
        let expectedFrameRateHint = targetFrameRate
        let maximumRealTimeFrameRateHint =
            (codec == .hevc && isHighRefreshHDRHEVC && !shouldEnableLowLatencyRateControl)
            ? max((targetFrameRate * 15) / 8, targetFrameRate)
            : nil
        let expectedDurationHint = 1.0 / Double(expectedFrameRateHint)
        let vbvBufferDurationSeconds: Double? =
            (isHighRefreshHDRHEVC && shouldEnableLowLatencyRateControl)
            ? (1.0 / 30.0)
            : nil
        let vbvInitialDelayPercentage: Double? =
            (codec == .hevc && isHighRefreshLowLatency && !shouldEnableLowLatencyRateControl)
            ? 0
            : nil
        let maxFrameDelayCount = MDKVideoToolboxLatencyPolicy.maxFrameDelayCount(
            codec: codec,
            targetFrameRate: targetFrameRate
        )

        setSessionProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, label: "RealTime")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ProgressiveScan, value: kCFBooleanTrue, label: "ProgressiveScan")
        setSessionProperty(
            session,
            key: kVTCompressionPropertyKey_AllowTemporalCompression,
            value: allowsTemporalCompression ? kCFBooleanTrue : kCFBooleanFalse,
            label: "AllowTemporalCompression"
        )
        setSessionProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, label: "AllowFrameReordering")
        setSessionProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse, label: "AllowOpenGOP")
        setSessionProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue, label: "PrioritizeEncodingSpeedOverQuality")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse, label: "MaximizePowerEfficiency")
        setSessionProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: maxFrameDelayCount),
            label: "MaxFrameDelayCount"
        )
        setSessionProperty(session, key: kVTCompressionPropertyKey_ExpectedDuration, value: NSNumber(value: expectedDurationHint), label: "ExpectedDuration")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: expectedFrameRateHint), label: "ExpectedFrameRate")
        if #available(macOS 15.0, *),
            let maximumRealTimeFrameRateHint {
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_MaximumRealTimeFrameRate,
                value: NSNumber(value: maximumRealTimeFrameRateHint),
                label: "MaximumRealTimeFrameRate"
            )
        }
        if #available(macOS 26.0, *),
            let vbvBufferDurationSeconds {
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_VBVBufferDuration,
                value: NSNumber(value: vbvBufferDurationSeconds),
                label: "VBVBufferDuration"
            )
        }
        if #available(macOS 26.0, *),
            let vbvInitialDelayPercentage {
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_VBVInitialDelayPercentage,
                value: NSNumber(value: vbvInitialDelayPercentage),
                label: "VBVInitialDelayPercentage"
            )
        }
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: targetFrameRate), label: "MaxKeyFrameInterval")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0), label: "MaxKeyFrameIntervalDuration")
        if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_OutputBitDepth,
                value: NSNumber(value: 10),
                label: "OutputBitDepth"
            )
        }
        if codec.supportsAverageBitRate {
            let averageBitRate = resolvedAverageBitRate(
                width: width,
                height: height,
                isHighRefreshLowLatency: isHighRefreshLowLatency
            )
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: averageBitRate),
                label: "AverageBitRate"
            )
        }
        if codec.supportsDataRateLimits {
            let dataRateLimits = resolvedDataRateLimits(
                width: width,
                height: height,
                isHighRefreshLowLatency: isHighRefreshLowLatency
            )
            setSessionProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: dataRateLimits as CFArray,
                label: "DataRateLimits"
            )
        }
        if codec.supportsQualityProperty && !isHighRefreshLowLatency {
            setSessionProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: codec.targetQuality), label: "Quality")
        }
        if codec.supportsReferenceBufferCount {
            setSessionProperty(session, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: NSNumber(value: codec.referenceBufferCount), label: "ReferenceBufferCount")
        }
        if let profileLevel = codec.defaultProfileLevel(for: pixelFormat) {
            setSessionProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel, label: "ProfileLevel")
            sessionConfigurationNotes.append("videoToolboxConfiguredProfileLevel=\(profileLevel)")
        }
        if let hdrConfiguration {
            for property in hdrConfiguration.sessionProperties {
                setSessionProperty(
                    session,
                    key: property.0,
                    value: property.1,
                    label: property.2
                )
            }
        }
        let shouldPrepareToEncodeFrames = !(
            codec == .hevc &&
            tileMetadata.tileCount > 1 &&
            hdrConfiguration?.transferFunction == .smpteSt2084PQ
        )
        if shouldPrepareToEncodeFrames {
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepareStatus == noErr else {
                VTCompressionSessionInvalidate(session)
                throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: prepareStatus)
            }
        }

        compressionSession = session
        activeDimensions = SIMD2(width, height)
        activePixelFormat = pixelFormat
        sessionConfigurationNotes.append(String(format: "videoToolboxEncoderInputPixelFormat=0x%08X", pixelFormat))
        sessionConfigurationNotes.append("videoToolboxEncoderInputStrategy=\(encoderInputStrategy.rawValue)")
        sessionConfigurationNotes.append("videoToolboxEncodedWidth=\(width)")
        sessionConfigurationNotes.append("videoToolboxEncodedHeight=\(height)")
        sessionConfigurationNotes.append("videoToolboxPrepareToEncodeFrames=\(shouldPrepareToEncodeFrames ? "enabled" : "skipped-hevc-hdr-tile-stream")")
        sessionConfigurationNotes.append("videoToolboxTargetFrameRateHint=\(expectedFrameRateHint)")
        if #available(macOS 15.0, *),
            let maximumRealTimeFrameRateHint {
            sessionConfigurationNotes.append("videoToolboxConfiguredMaximumRealTimeFrameRate=\(maximumRealTimeFrameRateHint)")
        } else {
            sessionConfigurationNotes.append("videoToolboxConfiguredMaximumRealTimeFrameRate=default")
        }
        sessionConfigurationNotes.append("videoToolboxHighRefreshHDRLowLatencyMode=\(isHighRefreshHDRHEVC ? "enabled" : "disabled")")
        sessionConfigurationNotes.append("videoToolboxAllowTemporalCompression=\(allowsTemporalCompression ? "enabled" : "disabled")")
        sessionConfigurationNotes.append("videoToolboxConfiguredMaxFrameDelayCount=\(maxFrameDelayCount)")
        if let vbvBufferDurationSeconds {
            sessionConfigurationNotes.append("videoToolboxConfiguredVBVBufferDurationSeconds=\(vbvBufferDurationSeconds)")
        } else {
            sessionConfigurationNotes.append("videoToolboxConfiguredVBVBufferDurationSeconds=default")
        }
        if let vbvInitialDelayPercentage {
            sessionConfigurationNotes.append("videoToolboxConfiguredVBVInitialDelayPercentage=\(vbvInitialDelayPercentage)")
        } else {
            sessionConfigurationNotes.append("videoToolboxConfiguredVBVInitialDelayPercentage=default")
        }
        if codec.supportsAverageBitRate {
            let averageBitRate = resolvedAverageBitRate(
                width: width,
                height: height,
                isHighRefreshLowLatency: isHighRefreshLowLatency
            )
            sessionConfigurationNotes.append("videoToolboxConfiguredAverageBitRate=\(averageBitRate)")
            sessionConfigurationNotes.append(
                "videoToolboxConfiguredAverageBitRateSource=\(resolvedAverageBitRateSource(isHighRefreshLowLatency: isHighRefreshLowLatency))"
            )
        } else {
            sessionConfigurationNotes.append("videoToolboxConfiguredAverageBitRate=default")
        }
        if codec.supportsDataRateLimits {
            let dataRateLimitsDescription = resolvedDataRateLimits(
                width: width,
                height: height,
                isHighRefreshLowLatency: isHighRefreshLowLatency
            )
                .map(\.stringValue)
                .joined(separator: ",")
            sessionConfigurationNotes.append("videoToolboxConfiguredDataRateLimits=\(dataRateLimitsDescription)")
            sessionConfigurationNotes.append(
                "videoToolboxConfiguredDataRateLimitsSource=\(resolvedAverageBitRateSource(isHighRefreshLowLatency: isHighRefreshLowLatency))"
            )
        } else {
            sessionConfigurationNotes.append("videoToolboxConfiguredDataRateLimits=default")
        }
        sessionConfigurationNotes.append("videoToolboxHighRefreshLowLatencyMode=\(isHighRefreshLowLatency ? "enabled" : "disabled")")
        sessionConfigurationNotes.append("videoToolboxLowLatencyRateControl=\(shouldEnableLowLatencyRateControl ? "enabled" : "disabled")")
        usingHardwareAcceleratedEncoder = copyBooleanSessionProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
        )
        encoderPixelBufferPoolIsShared = copyBooleanSessionProperty(
            session,
            key: kVTCompressionPropertyKey_PixelBufferPoolIsShared
        )
        encoderPixelBufferAttributes = copyDictionarySessionProperty(
            session,
            key: kVTCompressionPropertyKey_VideoEncoderPixelBufferAttributes
        )
        if #available(macOS 14.0, *) {
            recommendedParallelizationLimit = copyIntegerSessionProperty(
                session,
                key: kVTCompressionPropertyKey_RecommendedParallelizationLimit
            )
        } else {
            recommendedParallelizationLimit = nil
        }
    }

    private func makeEncoderSpecification() -> CFDictionary {
        var encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true as CFBoolean
        ]
        if shouldEnableLowLatencyRateControl {
            encoderSpecification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true as CFBoolean
        }
        return encoderSpecification as CFDictionary
    }

    private var shouldEnableLowLatencyRateControl: Bool {
        guard codec.lowLatencyRateControlSupported else {
            return false
        }

        return !(
            codec == .hevc &&
            hdrConfiguration?.transferFunction == .smpteSt2084PQ
        )
    }

    private func resolvedAverageBitRate(
        width: Int,
        height: Int,
        isHighRefreshLowLatency: Bool
    ) -> Int {
        if let targetAverageBitRateBitsPerSecond {
            return targetAverageBitRateBitsPerSecond
        }
        return isHighRefreshLowLatency
            ? codec.lowLatencyAverageBitRate(width: width, height: height, frameRate: targetFrameRate)
            : codec.averageBitRate(width: width, height: height, frameRate: targetFrameRate)
    }

    private func resolvedDataRateLimits(
        width: Int,
        height: Int,
        isHighRefreshLowLatency: Bool
    ) -> [NSNumber] {
        if let targetAverageBitRateBitsPerSecond {
            return codec.dataRateLimits(
                forAverageBitRate: targetAverageBitRateBitsPerSecond,
                lowLatency: isHighRefreshLowLatency
            )
        }
        return isHighRefreshLowLatency
            ? codec.lowLatencyDataRateLimits(width: width, height: height, frameRate: targetFrameRate)
            : codec.dataRateLimits(width: width, height: height, frameRate: targetFrameRate)
    }

    private func resolvedAverageBitRateSource(isHighRefreshLowLatency: Bool) -> String {
        if targetAverageBitRateBitsPerSecond != nil {
            return "apollo-requested"
        }
        return isHighRefreshLowLatency ? "low-latency-heuristic" : "codec-default"
    }

    private func setSessionProperty(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef,
        label: String
    ) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status != noErr else {
            return
        }

        sessionConfigurationNotes.append("videoToolboxProperty.\(label)=\(describe(status: status))")
    }

    private func acquireStagingSlot(
        width: Int,
        height: Int,
        pixelFormat: UInt32,
        device: any MTLDevice
    ) throws -> MDKVideoToolboxStagingSlot {
        try ensureStagingPool(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )

        if let reusableIdentifier = availableStagingSlotIdentifiers.popLast(),
           let reusableSlot = stagingSlots[reusableIdentifier] {
            return reusableSlot
        }

        guard stagingSlots.count < maxInflightStagingSlots else {
            throw MDKVideoToolboxProcessingError.stagingSlotUnavailable
        }

        guard let stagingPixelBufferPool else {
            throw MDKVideoToolboxProcessingError.stagingPoolCreationFailed(status: kCVReturnError)
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            stagingPixelBufferPool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MDKVideoToolboxProcessingError.stagingBufferCreationFailed(status: status)
        }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            throw MDKVideoToolboxProcessingError.stagingSurfaceUnavailable
        }

        let slotIdentifier = nextStagingSlotIdentifier
        nextStagingSlotIdentifier += 1
        let stagingSurface = MDKCaptureSurface(ioSurface: surface)
        let textures = try makeTextures(
            for: stagingSurface,
            device: device,
            usage: [.shaderRead, .shaderWrite]
        )
        let slot = MDKVideoToolboxStagingSlot(
            identifier: slotIdentifier,
            pixelBuffer: pixelBuffer,
            surface: stagingSurface,
            textures: textures
        )
        stagingSlots[slotIdentifier] = slot
        return slot
    }

    private func ensureStagingPool(
        width: Int,
        height: Int,
        pixelFormat: UInt32
    ) throws {
        if let activeDimensions,
           activePixelFormat == pixelFormat,
           activeDimensions == SIMD2(width, height),
           stagingPixelBufferPool != nil {
            return
        }

        var attributes = (encoderPixelBufferAttributes as? [CFString: Any]) ?? [:]
        attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat
        attributes[kCVPixelBufferWidthKey] = width
        attributes[kCVPixelBufferHeightKey] = height
        attributes[kCVPixelBufferMetalCompatibilityKey] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey] = [:] as [CFString: Any]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: min(maxInflightStagingSlots, 12)
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw MDKVideoToolboxProcessingError.stagingPoolCreationFailed(status: status)
        }

        stagingPixelBufferPool = pool
        stagingSlots.removeAll(keepingCapacity: true)
        availableStagingSlotIdentifiers.removeAll(keepingCapacity: true)
        nextStagingSlotIdentifier = 0
    }

    private func makeTextures(
        for surface: MDKCaptureSurface,
        device: any MTLDevice,
        usage: MTLTextureUsage
    ) throws -> [MTLTexture] {
        let planeCount = max(surface.planeCount, 1)
        var textures: [MTLTexture] = []
        textures.reserveCapacity(planeCount)

        for plane in 0..<planeCount {
            guard let texture = try surface.makeMetalTexture(
                device: device,
                plane: plane,
                usage: usage
            ) else {
                throw MDKVideoToolboxProcessingError.stagingTextureBindingFailed(plane: plane)
            }
            textures.append(texture)
        }

        return textures
    }

    private func makeSourceTextures(
        for frame: MDKCaptureFrame,
        surface: MDKCaptureSurface,
        device: any MTLDevice
    ) throws -> [MTLTexture] {
        try makeSourceTextures(
            forSurfaceID: frame.surfaceID,
            surface: surface,
            device: device
        )
    }

    private func makeCursorTexture(
        for cursorOverlaySample: MDKCursorOverlaySample?,
        device: any MTLDevice
    ) throws -> MTLTexture? {
        guard let cursorOverlaySample else {
            return nil
        }

        let textures = try makeSourceTextures(
            forSurfaceID: cursorOverlaySample.surface.id,
            surface: cursorOverlaySample.surface,
            device: device
        )
        return textures.first
    }

    private func makeSourceTextures(
        forSurfaceID surfaceID: UInt32,
        surface: MDKCaptureSurface,
        device: any MTLDevice
    ) throws -> [MTLTexture] {
        let descriptors = try makePlaneDescriptors(for: surface)
        if let cachedEntry = sourceTextureCache[surfaceID],
           cachedEntry.descriptors == descriptors {
            return cachedEntry.textures
        }

        let textures = try makeTextures(
            for: surface,
            device: device,
            usage: [.shaderRead]
        )
        sourceTextureCache[surfaceID] = MDKVideoToolboxSourceTextureCacheEntry(
            descriptors: descriptors,
            textures: textures
        )
        if sourceTextureCache.count > maxInflightStagingSlots {
            sourceTextureCache.removeAll(keepingCapacity: true)
            sourceTextureCache[surfaceID] = MDKVideoToolboxSourceTextureCacheEntry(
                descriptors: descriptors,
                textures: textures
            )
        }
        return textures
    }

    private func scaledCursorOverlaySample(
        from cursorOverlaySample: MDKCursorOverlaySample?,
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> MDKCursorOverlaySample? {
        guard let cursorOverlaySample else {
            return nil
        }
        guard sourceWidth > 0, sourceHeight > 0 else {
            return cursorOverlaySample
        }

        let scaleX = CGFloat(destinationWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(destinationHeight) / CGFloat(sourceHeight)
        return MDKCursorOverlaySample(
            surface: cursorOverlaySample.surface,
            rect: CGRect(
                x: cursorOverlaySample.rect.minX * scaleX,
                y: cursorOverlaySample.rect.minY * scaleY,
                width: cursorOverlaySample.rect.width * scaleX,
                height: cursorOverlaySample.rect.height * scaleY
            ),
            isVerticallyFlipped: cursorOverlaySample.isVerticallyFlipped
        )
    }

    private func makePlaneDescriptors(
        for surface: MDKCaptureSurface
    ) throws -> [MDKMetalPlaneDescriptor] {
        let planeCount = max(surface.planeCount, 1)
        var descriptors: [MDKMetalPlaneDescriptor] = []
        descriptors.reserveCapacity(planeCount)
        for plane in 0..<planeCount {
            descriptors.append(try surface.metalPlaneDescriptor(for: plane))
        }
        return descriptors
    }

    private func requiresScaling(
        sourceTextures: [MTLTexture],
        destinationTextures: [MTLTexture]
    ) -> Bool {
        guard sourceTextures.count == destinationTextures.count else {
            return true
        }

        return zip(sourceTextures, destinationTextures).contains { sourceTexture, destinationTexture in
            sourceTexture.width != destinationTexture.width ||
            sourceTexture.height != destinationTexture.height
        }
    }

    private func wrappedPixelBuffer(
        for frame: MDKCaptureFrame,
        surface: MDKCaptureSurface
    ) throws -> CVPixelBuffer {
        if let cached = pixelBufferCache[frame.surfaceID] {
            return cached
        }

        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let pixelBufferStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface.rawIOSurface,
            pixelBufferAttributes,
            &pixelBuffer
        )
        guard pixelBufferStatus == kCVReturnSuccess, let pixelBuffer else {
            throw MDKVideoToolboxProcessingError.pixelBufferCreationFailed(status: pixelBufferStatus)
        }

        let wrappedBuffer = pixelBuffer.takeRetainedValue()
        pixelBufferCache[frame.surfaceID] = wrappedBuffer
        return wrappedBuffer
    }

    private func invalidateSession() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
        activeDimensions = nil
        activePixelFormat = nil
        pixelBufferAttributes = nil
        encoderPixelBufferAttributes = nil
        pixelBufferCache.removeAll(keepingCapacity: true)
        sourceTextureCache.removeAll(keepingCapacity: true)
        stagingPixelBufferPool = nil
        stagingSlots.removeAll(keepingCapacity: true)
        availableStagingSlotIdentifiers.removeAll(keepingCapacity: true)
        nextStagingSlotIdentifier = 0
        frameIndex = 0
        sessionConfigurationNotes.removeAll(keepingCapacity: true)
        directSubmissionFrameCount = 0
        stagedSubmissionFrameCount = 0
        outputQueue.sync {
            submittedFrameCount = 0
            outputCallbackCount = 0
            completedOutputFrameCount = 0
            outputCallbackStatusHistogram = [:]
            outputCallbackLatencyHistogram = [:]
            minOutputCallbackLatencyMilliseconds = nil
            maxOutputCallbackLatencyMilliseconds = nil
            encodeQueueWaitTiming = MDKVideoToolboxTimingAccumulator()
            encodeInvocationTiming = MDKVideoToolboxTimingAccumulator()
            metalStageTiming = MDKVideoToolboxTimingAccumulator()
            vtEncodeCallTiming = MDKVideoToolboxTimingAccumulator()
        }
        lastFreshReplayState = nil
        lastImmediateRecoveryReplayDisplayTime = nil
        immediateReplaySubmissionCount = 0
        suppressedImmediateReplayCount = 0
        usingHardwareAcceleratedEncoder = nil
        encoderPixelBufferPoolIsShared = nil
        recommendedParallelizationLimit = nil
    }

    private func recordProcessingSuccess(isStaged: Bool) {
        outputQueue.sync {
            processedFrameCount += 1
            if isStaged {
                stagedSubmissionFrameCount += 1
            } else {
                directSubmissionFrameCount += 1
            }
        }
    }

    private func recordProcessingFailure(_ description: String) {
        outputQueue.sync {
            processingFailureCount += 1
            processingErrorHistogram[description, default: 0] += 1
        }
    }

    fileprivate func recordOutputCallback(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        submissionToken: MDKVideoToolboxSubmissionToken?,
        callbackReceivedAt: TimeInterval
    ) {
        let outputCompleted = status == noErr && sampleBuffer != nil
        let latencyMilliseconds = submissionToken.map {
            max((callbackReceivedAt - $0.submittedAt) * 1000.0, 0)
        }
        let resolvedSampleBuffer = sampleBuffer.map { sampleBuffer in
            guard let hdrConfiguration else {
                return sampleBuffer
            }
            let isKeyFrame: Bool
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
               let firstAttachment = attachments.first {
                let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                isKeyFrame = !notSync
            } else {
                isKeyFrame = true
            }
            return MDKHEVCHDRStaticMetadataTransport.makeAugmentedSampleBufferIfNeeded(
                sampleBuffer: sampleBuffer,
                hdrConfiguration: hdrConfiguration,
                isKeyFrame: isKeyFrame
            ) ?? sampleBuffer
        }
        let sourceSequenceNumber = submissionToken?.sourceSequenceNumber ?? 0
        let resolvedTileMetadata = MDKEncodedFrameTileMetadata(
            frameGroupID: tileMetadata.frameGroupID == 0 ? sourceSequenceNumber : tileMetadata.frameGroupID,
            tileIndex: tileMetadata.tileIndex,
            tileCount: tileMetadata.tileCount,
            encodedLaneIndex: tileMetadata.encodedLaneIndex,
            encodedLaneCount: tileMetadata.encodedLaneCount,
            tileRegion: tileMetadata.tileRegion
        )
        let encodedFrame = resolvedSampleBuffer.map {
            MDKEncodedFrame(
                sampleBuffer: $0,
                codec: codec,
                sourceSequenceNumber: sourceSequenceNumber,
                sourceDisplayTime: submissionToken?.sourceDisplayTime ?? 0,
                outputCallbackLatencyMilliseconds: latencyMilliseconds,
                tileMetadata: resolvedTileMetadata
            )
        }
        if let slotIdentifier = submissionToken?.slotIdentifier {
            encodeQueue.async { [self] in
                releaseStagingSlot(identifier: slotIdentifier)
            }
        }
        submissionToken?.markCompleted()
        outputQueue.async { [self] in
            outputCallbackCount += 1
            outputCallbackStatusHistogram[describe(status: status), default: 0] += 1

            if let latencyMilliseconds {
                minOutputCallbackLatencyMilliseconds = min(
                    minOutputCallbackLatencyMilliseconds ?? latencyMilliseconds,
                    latencyMilliseconds
                )
                maxOutputCallbackLatencyMilliseconds = max(
                    maxOutputCallbackLatencyMilliseconds ?? latencyMilliseconds,
                    latencyMilliseconds
                )
                outputCallbackLatencyHistogram[roundedLatencyBucket(for: latencyMilliseconds), default: 0] += 1
            }

            if outputCompleted {
                completedOutputFrameCount += 1
            }
            if let encodedFrame, outputCompleted {
                outputHandler?(encodedFrame)
            } else if status != noErr {
                failureHandler?("VT output callback failed (\(describe(status: status))).")
            }
            outputDrainGroup.leave()
        }
    }

    private func describe(status: OSStatus) -> String {
        status == noErr ? "noErr" : String(status)
    }

    private func roundedLatencyBucket(for latencyMilliseconds: Double) -> String {
        let rounded = (latencyMilliseconds * 10.0).rounded() / 10.0
        return String(format: "%.1fms", rounded)
    }

    private func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    private func recordTiming(
        _ metric: MDKVideoToolboxTimingMetric,
        startedAt: TimeInterval,
        endedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let elapsedMilliseconds = (endedAt - startedAt) * 1000.0
        outputQueue.sync {
            switch metric {
            case .encodeQueueWait:
                encodeQueueWaitTiming.record(elapsedMilliseconds)
            case .encodeInvocation:
                encodeInvocationTiming.record(elapsedMilliseconds)
            case .metalStage:
                metalStageTiming.record(elapsedMilliseconds)
            case .vtEncodeCall:
                vtEncodeCallTiming.record(elapsedMilliseconds)
            }
        }
    }

    private func describeHardwareAcceleration(_ value: Bool?) -> String {
        switch value {
        case .some(true):
            return "true"
        case .some(false):
            return "false"
        case .none:
            return "unknown"
        }
    }

    private func copyBooleanSessionProperty(
        _ session: VTCompressionSession,
        key: CFString
    ) -> Bool? {
        guard let copiedValue = copySessionProperty(session, key: key) else {
            return nil
        }

        if CFGetTypeID(copiedValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((copiedValue as! CFBoolean))
        }

        return nil
    }

    private func copyDictionarySessionProperty(
        _ session: VTCompressionSession,
        key: CFString
    ) -> CFDictionary? {
        guard let copiedValue = copySessionProperty(session, key: key) else {
            return nil
        }

        guard CFGetTypeID(copiedValue) == CFDictionaryGetTypeID() else {
            return nil
        }

        return (copiedValue as! CFDictionary)
    }

    private func copyIntegerSessionProperty(
        _ session: VTCompressionSession,
        key: CFString
    ) -> Int? {
        guard let copiedValue = copySessionProperty(session, key: key) else {
            return nil
        }

        guard CFGetTypeID(copiedValue) == CFNumberGetTypeID() else {
            return nil
        }

        return (copiedValue as? NSNumber)?.intValue
    }

    private func copySessionProperty(
        _ session: VTCompressionSession,
        key: CFString
    ) -> CFTypeRef? {
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
        guard status == noErr else {
            return nil
        }
        return value?.takeRetainedValue()
    }

    private func releaseStagingSlot(identifier: Int) {
        if DispatchQueue.getSpecific(key: encodeQueueSpecificKey) != encodeQueueSpecificValue {
            encodeQueue.async { [self] in
                releaseStagingSlot(identifier: identifier)
            }
            return
        }

        guard stagingSlots[identifier] != nil else {
            return
        }

        if !availableStagingSlotIdentifiers.contains(identifier) {
            availableStagingSlotIdentifiers.append(identifier)
        }
    }
}
