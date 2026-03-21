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

private let MDKVideoToolboxOutputCallback: VTCompressionOutputCallback = { _, _, _, _, _ in
    // Raw benchmark mode only needs encode submission/completion viability.
}

public final class MDKVideoToolboxEncodingProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    private var compressionSession: VTCompressionSession?
    private var activeDimensions: SIMD2<Int>?
    private var activePixelFormat: UInt32?
    private var pixelBufferAttributes: CFDictionary?
    private var pixelBufferCache: [UInt32: CVPixelBuffer] = [:]
    private var frameIndex: Int64 = 0
    private var processedFrameCount: UInt64 = 0
    private var processingFailureCount: UInt64 = 0
    private var processingErrorHistogram: [String: Int] = [:]
    private let encodeQueue = DispatchQueue(label: "com.skyline23.MacDisplayKit.capture.videotoolbox.encode")

    public init() {}

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
            return MDKCaptureFrameProcessingSummary(
                processedFrameCount: processedFrameCount,
                processingFailureCount: processingFailureCount,
                processingErrorHistogram: processingErrorHistogram,
                notes: [
                    "videoToolboxSubmitMode=async-queue",
                    "videoToolboxOutputCallback=non-nil",
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

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
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
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true as CFBoolean
            ] as CFDictionary,
            imageBufferAttributes: sourceImageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: MDKVideoToolboxOutputCallback,
            refcon: nil,
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MDKVideoToolboxProcessingError.compressionSessionCreationFailed(status: prepareStatus)
        }

        compressionSession = session
        activeDimensions = SIMD2(width, height)
        activePixelFormat = pixelFormat
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
    }
}
