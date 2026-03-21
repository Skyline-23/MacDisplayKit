import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

public enum MDKVideoToolboxProcessingError: Error, LocalizedError, Equatable {
    case surfaceUnavailable
    case pixelBufferCreationFailed(status: CVReturn)
    case compressionSessionCreationFailed(status: OSStatus)
    case encodeFailed(status: OSStatus)

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
        }
    }
}

private final class MDKVideoToolboxSubmissionToken {
    let submittedAt: TimeInterval

    init(submittedAt: TimeInterval) {
        self.submittedAt = submittedAt
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

    private var compressionSession: VTCompressionSession?
    private var activeDimensions: SIMD2<Int>?
    private var activePixelFormat: UInt32?
    private var pixelBufferAttributes: CFDictionary?
    private var pixelBufferCache: [UInt32: CVPixelBuffer] = [:]
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
    private let encodeQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.encode")

    public init(codec: MDKVideoEncoderCodec = .hevc) {
        self.codec = codec
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
                    "videoToolboxUsingHardwareEncoder=\(describeHardwareAcceleration(usingHardwareAcceleratedEncoder))",
                    "videoToolboxPixelBufferCacheSize=\(pixelBufferCache.count)"
                ]
            )
        }
    }

    private func encode(frame: MDKCaptureFrame) throws {
        try ensureCompressionSession(
            width: frame.width,
            height: frame.height,
            pixelFormat: frame.pixelFormat
        )

        guard let surface = frame.surface else {
            throw MDKVideoToolboxProcessingError.surfaceUnavailable
        }

        let imageBuffer = try wrappedPixelBuffer(for: frame, surface: surface)

        guard let compressionSession else {
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: OSStatus(unimpErr))
        }

        let presentationTimeStamp = CMTime(value: frameIndex, timescale: 120)
        frameIndex += 1
        let submissionToken = Unmanaged.passRetained(
            MDKVideoToolboxSubmissionToken(submittedAt: ProcessInfo.processInfo.systemUptime)
        )

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
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

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true as CFBoolean
            ] as CFDictionary,
            imageBufferAttributes: sourceImageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: MDKVideoToolboxOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: status)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProgressiveScan, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedDuration, value: (1.0 / 120.0) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 120 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFTypeRef)
        if let profileLevel = codec.defaultProfileLevel {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: prepareStatus)
        }

        compressionSession = session
        activeDimensions = SIMD2(width, height)
        activePixelFormat = pixelFormat
        usingHardwareAcceleratedEncoder = copyBooleanSessionProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
        )
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
        frameIndex = 0
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
}
