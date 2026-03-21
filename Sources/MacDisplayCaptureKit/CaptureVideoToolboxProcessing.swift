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
        }
    }
}

private final class MDKVideoToolboxSubmissionToken {
    let slotIdentifier: Int?
    let submittedAt: TimeInterval

    init(slotIdentifier: Int?, submittedAt: TimeInterval) {
        self.slotIdentifier = slotIdentifier
        self.submittedAt = submittedAt
    }
}

private struct MDKVideoToolboxStagingSlot {
    let identifier: Int
    let pixelBuffer: CVPixelBuffer
    let surface: MDKCaptureSurface
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
    private let device: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private let scaler: MDKMetalBilinearScaler?
    private let maxInflightStagingSlots: Int

    private var compressionSession: VTCompressionSession?
    private var activeDimensions: SIMD2<Int>?
    private var activePixelFormat: UInt32?
    private var pixelBufferAttributes: CFDictionary?
    private var pixelBufferCache: [UInt32: CVPixelBuffer] = [:]
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
    private var usingHardwareAcceleratedEncoder: Bool?
    private var sessionConfigurationNotes: [String] = []
    private let encodeQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.encode")

    public init(
        codec: MDKVideoEncoderCodec = .hevc,
        preprocessStrategy: MDKVideoPreprocessStrategy = .none,
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        maxInflightStagingSlots: Int = 128
    ) {
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.scaler = device.map { MDKMetalBilinearScaler(device: $0) }
        self.maxInflightStagingSlots = max(maxInflightStagingSlots, 1)
    }

    deinit {
        encodeQueue.sync {
            invalidateSession()
        }
    }

    public func process(frame: MDKCaptureFrame) throws {
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
            surface: surface
        )
        encodeQueue.async { [self, retainedFrame] in
            do {
                try encode(frame: retainedFrame)
                processedFrameCount += 1
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                processingFailureCount += 1
                processingErrorHistogram[errorDescription, default: 0] += 1
            }
        }
    }

    func finalize() -> MDKCaptureFrameProcessingSummary? {
        encodeQueue.sync { [self] in
            if let compressionSession {
                VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            }
            let outputSummary = outputQueue.sync {
                (
                    outputCallbackCount,
                    completedOutputFrameCount,
                    outputCallbackStatusHistogram,
                    outputCallbackLatencyHistogram,
                    minOutputCallbackLatencyMilliseconds,
                    maxOutputCallbackLatencyMilliseconds
                )
            }
            return MDKCaptureFrameProcessingSummary(
                processedFrameCount: processedFrameCount,
                processingFailureCount: processingFailureCount,
                processingErrorHistogram: processingErrorHistogram,
                outputCallbackCount: outputSummary.0,
                completedOutputFrameCount: outputSummary.1,
                outputCallbackStatusHistogram: outputSummary.2,
                outputCallbackLatencyHistogram: outputSummary.3,
                minOutputCallbackLatencyMilliseconds: outputSummary.4,
                maxOutputCallbackLatencyMilliseconds: outputSummary.5,
                notes: [
                    "videoToolboxSubmitMode=async-queue",
                    "videoToolboxOutputCallback=non-nil",
                    "videoToolboxCodec=\(codec.rawValue)",
                    "videoToolboxPreprocessStrategy=\(preprocessStrategy.rawValue)",
                    "videoToolboxStagingMode=\(commandQueue == nil ? "direct-iosurface" : "metal-staging-pool")",
                    "videoToolboxMaxInflightStagingSlots=\(maxInflightStagingSlots)",
                    "videoToolboxUsingHardwareEncoder=\(describeHardwareAcceleration(usingHardwareAcceleratedEncoder))",
                    "videoToolboxPixelBufferCacheSize=\(pixelBufferCache.count)"
                ] + sessionConfigurationNotes
            )
        }
    }

    private func encode(frame: MDKCaptureFrame) throws {
        let outputDimensions = preprocessStrategy.outputDimensions(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            pixelFormat: frame.pixelFormat
        )
        try ensureCompressionSession(
            width: outputDimensions.x,
            height: outputDimensions.y,
            pixelFormat: frame.pixelFormat
        )

        if let commandQueue {
            try stageAndEncode(frame: frame, commandQueue: commandQueue)
        } else {
            try encodeDirect(frame: frame)
        }
    }

    private func encodeDirect(frame: MDKCaptureFrame) throws {
        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let imageBuffer = try wrappedPixelBuffer(for: frame, surface: surface)
        try submitToEncoder(imageBuffer: imageBuffer, slotIdentifier: nil)
    }

    private func stageAndEncode(
        frame: MDKCaptureFrame,
        commandQueue: any MTLCommandQueue
    ) throws {
        guard let device else {
            throw MDKVideoToolboxProcessingError.metalDeviceUnavailable
        }
        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let sourceTextures = try makeTextures(
            for: surface,
            device: device,
            usage: [.shaderRead]
        )
        let outputDimensions = preprocessStrategy.outputDimensions(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            pixelFormat: frame.pixelFormat
        )
        let slot = try acquireStagingSlot(
            width: outputDimensions.x,
            height: outputDimensions.y,
            pixelFormat: frame.pixelFormat,
            device: device
        )
        let slotIdentifier = slot.identifier

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            releaseStagingSlot(identifier: slotIdentifier)
            throw MDKVideoToolboxProcessingError.commandBufferUnavailable
        }
        let presentationTimeStamp = CMTime(value: frameIndex, timescale: 120)
        frameIndex += 1

        if requiresScaling(sourceTextures: sourceTextures, destinationTextures: slot.textures) {
            guard let scaler else {
                releaseStagingSlot(identifier: slotIdentifier)
                throw MDKVideoToolboxProcessingError.scalerUnavailable
            }
            scaler.encode(
                commandBuffer: commandBuffer,
                sourceTextures: sourceTextures,
                destinationTextures: slot.textures
            )
        } else {
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                releaseStagingSlot(identifier: slotIdentifier)
                throw MDKVideoToolboxProcessingError.blitEncoderUnavailable
            }

            for (sourceTexture, destinationTexture) in zip(sourceTextures, slot.textures) {
                let copySize = MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1)
                blitEncoder.copy(
                    from: sourceTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: copySize,
                    to: destinationTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blitEncoder.endEncoding()
        }
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            guard let self else {
                return
            }
            let commandBufferStatus = commandBuffer.status
            self.encodeQueue.async {
                guard commandBufferStatus == .completed else {
                    self.processingFailureCount += 1
                    self.processingErrorHistogram["Metal staged copy failed (\(commandBufferStatus.rawValue)).", default: 0] += 1
                    self.releaseStagingSlot(identifier: slotIdentifier)
                    return
                }
                guard let slot = self.stagingSlots[slotIdentifier] else {
                    self.processingFailureCount += 1
                    self.processingErrorHistogram["Metal staged slot \(slotIdentifier) was missing before encode submit.", default: 0] += 1
                    return
                }

                do {
                    try self.submitToEncoder(
                        imageBuffer: slot.pixelBuffer,
                        slotIdentifier: slotIdentifier,
                        presentationTimeStamp: presentationTimeStamp
                    )
                } catch {
                    let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    self.processingFailureCount += 1
                    self.processingErrorHistogram[errorDescription, default: 0] += 1
                    self.releaseStagingSlot(identifier: slotIdentifier)
                }
            }
        }
        commandBuffer.commit()
    }

    private func submitToEncoder(
        imageBuffer: CVPixelBuffer,
        slotIdentifier: Int?,
        presentationTimeStamp: CMTime? = nil
    ) throws {
        guard let compressionSession else {
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: OSStatus(unimpErr))
        }

        let resolvedPresentationTimeStamp = presentationTimeStamp ?? {
            let timestamp = CMTime(value: frameIndex, timescale: 120)
            frameIndex += 1
            return timestamp
        }()
        let submissionToken = Unmanaged.passRetained(
            MDKVideoToolboxSubmissionToken(
                slotIdentifier: slotIdentifier,
                submittedAt: ProcessInfo.processInfo.systemUptime
            )
        )

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: resolvedPresentationTimeStamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: submissionToken.toOpaque(),
            infoFlagsOut: nil
        )
        guard status == noErr else {
            submissionToken.release()
            throw MDKVideoToolboxProcessingError.encodeFailed(status: status)
        }
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

        let averageBitRate = codec.averageBitRate(width: width, height: height, frameRate: 120)
        let dataRateLimits = codec.dataRateLimits(width: width, height: height, frameRate: 120) as CFArray

        setSessionProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, label: "RealTime")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ProgressiveScan, value: kCFBooleanTrue, label: "ProgressiveScan")
        setSessionProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue, label: "AllowTemporalCompression")
        setSessionProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, label: "AllowFrameReordering")
        setSessionProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse, label: "AllowOpenGOP")
        setSessionProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue, label: "PrioritizeEncodingSpeedOverQuality")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse, label: "MaximizePowerEfficiency")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1), label: "MaxFrameDelayCount")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ExpectedDuration, value: NSNumber(value: 1.0 / 120.0), label: "ExpectedDuration")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 120), label: "ExpectedFrameRate")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 120), label: "MaxKeyFrameInterval")
        setSessionProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1.0), label: "MaxKeyFrameIntervalDuration")
        setSessionProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: averageBitRate), label: "AverageBitRate")
        setSessionProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits, label: "DataRateLimits")
        setSessionProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: codec.targetQuality), label: "Quality")
        setSessionProperty(session, key: kVTCompressionPropertyKey_ReferenceBufferCount, value: NSNumber(value: codec.referenceBufferCount), label: "ReferenceBufferCount")
        if let profileLevel = codec.defaultProfileLevel {
            setSessionProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel, label: "ProfileLevel")
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: prepareStatus)
        }

        compressionSession = session
        activeDimensions = SIMD2(width, height)
        activePixelFormat = pixelFormat
        let dataRateLimitsDescription = codec
            .dataRateLimits(width: width, height: height, frameRate: 120)
            .map(\.stringValue)
            .joined(separator: ",")
        sessionConfigurationNotes.append("videoToolboxEncodedWidth=\(width)")
        sessionConfigurationNotes.append("videoToolboxEncodedHeight=\(height)")
        sessionConfigurationNotes.append("videoToolboxConfiguredAverageBitRate=\(averageBitRate)")
        sessionConfigurationNotes.append("videoToolboxConfiguredDataRateLimits=\(dataRateLimitsDescription)")
        usingHardwareAcceleratedEncoder = copyBooleanSessionProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
        )
    }

    private func makeEncoderSpecification() -> CFDictionary {
        var encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true as CFBoolean
        ]
        if codec.lowLatencyRateControlSupported {
            encoderSpecification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true as CFBoolean
        }
        return encoderSpecification as CFDictionary
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

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: maxInflightStagingSlots
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
        pixelBufferCache.removeAll(keepingCapacity: true)
        stagingPixelBufferPool = nil
        stagingSlots.removeAll(keepingCapacity: true)
        availableStagingSlotIdentifiers.removeAll(keepingCapacity: true)
        nextStagingSlotIdentifier = 0
        frameIndex = 0
        sessionConfigurationNotes.removeAll(keepingCapacity: true)
        outputQueue.sync {
            outputCallbackCount = 0
            completedOutputFrameCount = 0
            outputCallbackStatusHistogram = [:]
            outputCallbackLatencyHistogram = [:]
            minOutputCallbackLatencyMilliseconds = nil
            maxOutputCallbackLatencyMilliseconds = nil
        }
        usingHardwareAcceleratedEncoder = nil
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
        if let slotIdentifier = submissionToken?.slotIdentifier {
            encodeQueue.async { [self] in
                releaseStagingSlot(identifier: slotIdentifier)
            }
        }

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
        }
    }

    private func describe(status: OSStatus) -> String {
        status == noErr ? "noErr" : String(status)
    }

    private func roundedLatencyBucket(for latencyMilliseconds: Double) -> String {
        let rounded = (latencyMilliseconds * 10.0).rounded() / 10.0
        return String(format: "%.1fms", rounded)
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
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
        guard status == noErr, let copiedValue = value?.takeRetainedValue() else {
            return nil
        }

        if CFGetTypeID(copiedValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((copiedValue as! CFBoolean))
        }

        return nil
    }

    private func releaseStagingSlot(identifier: Int) {
        guard stagingSlots[identifier] != nil else {
            return
        }

        if !availableStagingSlotIdentifiers.contains(identifier) {
            availableStagingSlotIdentifiers.append(identifier)
        }
    }
}
