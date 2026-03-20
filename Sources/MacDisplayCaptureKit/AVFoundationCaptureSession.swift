import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

private func MDKFrameDuration(for frameRate: Int) -> CMTime {
    if frameRate <= 0 {
        return CMTime(value: 1, timescale: 60)
    }

    if frameRate > 60 {
        return .zero
    }

    return CMTime(value: 1, timescale: CMTimeScale(frameRate))
}

struct MDKAVFoundationScreenInputConfiguration: Equatable {
    let minFrameDuration: CMTime
    let capturesCursor: Bool
    let capturesMouseClicks: Bool
    let cropRect: CGRect
    let scaleFactor: CGFloat
}

struct MDKAVFoundationVideoOutputConfiguration: Equatable {
    let videoSettings: [String: AnyHashable]
    let alwaysDiscardsLateVideoFrames: Bool
}

private func MDKCaptureScaleFactor(
    requestedWidth: Int,
    requestedHeight: Int,
    logicalWidth: Int,
    logicalHeight: Int
) -> CGFloat {
    guard requestedWidth > 0, requestedHeight > 0, logicalWidth > 0, logicalHeight > 0 else {
        return 1.0
    }

    let widthScale = CGFloat(requestedWidth) / CGFloat(logicalWidth)
    let heightScale = CGFloat(requestedHeight) / CGFloat(logicalHeight)
    let scale = min(widthScale, heightScale)
    return max(scale, 0.01)
}

private func MDKDisplayLogicalSize(displayID: CGDirectDisplayID) -> CGSize {
    guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
        return CGSize(
            width: CGFloat(CGDisplayPixelsWide(displayID)),
            height: CGFloat(CGDisplayPixelsHigh(displayID))
        )
    }

    return CGSize(
        width: CGFloat(displayMode.width),
        height: CGFloat(displayMode.height)
    )
}

func makeMDKAVFoundationScreenInputConfiguration(
    for configuration: MDKCaptureConfiguration,
    logicalSize: CGSize
) -> MDKAVFoundationScreenInputConfiguration {
    return MDKAVFoundationScreenInputConfiguration(
        minFrameDuration: MDKFrameDuration(for: configuration.frameRate),
        capturesCursor: false,
        capturesMouseClicks: false,
        cropRect: CGRect(origin: .zero, size: logicalSize),
        scaleFactor: MDKCaptureScaleFactor(
            requestedWidth: configuration.width,
            requestedHeight: configuration.height,
            logicalWidth: Int(logicalSize.width),
            logicalHeight: Int(logicalSize.height)
        )
    )
}

func makeMDKAVFoundationVideoOutputConfiguration(
    for configuration: MDKCaptureConfiguration
) -> MDKAVFoundationVideoOutputConfiguration {
    return MDKAVFoundationVideoOutputConfiguration(
        videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: configuration.pixelFormat),
            kCVPixelBufferWidthKey as String: NSNumber(value: configuration.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: configuration.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: AnyHashable],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ],
        alwaysDiscardsLateVideoFrames: true
    )
}

final class MDKAVFoundationCaptureDriver: NSObject, MDKCaptureSessionDriver {
    let backend: MDKCaptureBackend = .avFoundation

    private let configuration: MDKCaptureConfiguration
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var session: AVCaptureSession?
    private var frameHandler: MDKCaptureFrameHandler?
    private var currentStats = MDKCaptureSessionStatistics.zero
    private var running = false
    private var nextSequenceNumber: UInt64 = 0

    init(configuration: MDKCaptureConfiguration) {
        self.configuration = configuration
        self.queue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.capture.avfoundation.\(configuration.displayID)",
            qos: .userInitiated
        )
        super.init()
    }

    var isRunning: Bool {
        lock.lock()
        let snapshot = running
        lock.unlock()
        return snapshot
    }

    var statistics: MDKCaptureSessionStatistics {
        lock.lock()
        let snapshot = currentStats
        lock.unlock()
        return snapshot
    }

    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws {
        lock.lock()
        if running {
            lock.unlock()
            throw MDKCaptureSessionError.alreadyRunning
        }
        lock.unlock()

        guard let screenInput = AVCaptureScreenInput(displayID: CGDirectDisplayID(configuration.displayID)) else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }
        let logicalSize = MDKDisplayLogicalSize(displayID: CGDirectDisplayID(configuration.displayID))
        let screenInputConfiguration = makeMDKAVFoundationScreenInputConfiguration(
            for: configuration,
            logicalSize: logicalSize
        )
        screenInput.minFrameDuration = screenInputConfiguration.minFrameDuration
        screenInput.capturesCursor = screenInputConfiguration.capturesCursor
        screenInput.capturesMouseClicks = screenInputConfiguration.capturesMouseClicks
        screenInput.cropRect = screenInputConfiguration.cropRect
        screenInput.scaleFactor = screenInputConfiguration.scaleFactor

        let session = AVCaptureSession()
        guard session.canAddInput(screenInput) else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }
        session.addInput(screenInput)

        let output = AVCaptureVideoDataOutput()
        let outputConfiguration = makeMDKAVFoundationVideoOutputConfiguration(for: configuration)
        output.videoSettings = outputConfiguration.videoSettings
        output.alwaysDiscardsLateVideoFrames = outputConfiguration.alwaysDiscardsLateVideoFrames
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }
        session.addOutput(output)

        lock.lock()
        self.frameHandler = frameHandler
        self.session = session
        currentStats = .zero
        nextSequenceNumber = 0
        running = true
        lock.unlock()

        session.startRunning()
    }

    func stop() {
        let sessionToStop: AVCaptureSession?
        lock.lock()
        sessionToStop = session
        frameHandler = nil
        session = nil
        running = false
        lock.unlock()

        sessionToStop?.stopRunning()
    }
}

extension MDKAVFoundationCaptureDriver: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock()
            currentStats = MDKCaptureSessionStatistics(
                callbackCount: currentStats.callbackCount + 1,
                deliveredFrameCount: currentStats.deliveredFrameCount,
                skippedFrameCount: currentStats.skippedFrameCount + 1,
                lastDisplayTime: currentStats.lastDisplayTime
            )
            lock.unlock()
            return
        }

        let displayTime = UInt64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let surfaceID: UInt32
        let captureSurface: MDKCaptureSurface?
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            surfaceID = IOSurfaceGetID(surface)
            captureSurface = MDKCaptureSurface(ioSurface: surface)
        } else {
            surfaceID = 0
            captureSurface = nil
        }

        let callback: MDKCaptureFrameHandler?
        let sequenceNumber: UInt64
        lock.lock()
        nextSequenceNumber += 1
        sequenceNumber = nextSequenceNumber
        currentStats = MDKCaptureSessionStatistics(
            callbackCount: currentStats.callbackCount + 1,
            deliveredFrameCount: currentStats.deliveredFrameCount + 1,
            skippedFrameCount: currentStats.skippedFrameCount,
            lastDisplayTime: displayTime
        )
        callback = frameHandler
        lock.unlock()

        _ = output
        _ = connection

        callback?(
            MDKCaptureFrame(
                sequenceNumber: sequenceNumber,
                displayTime: displayTime,
                surfaceID: surfaceID,
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                surface: captureSurface
            )
        )
    }
}
