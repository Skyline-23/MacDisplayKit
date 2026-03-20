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
}

func makeMDKAVFoundationScreenInputConfiguration(
    for configuration: MDKCaptureConfiguration
) -> MDKAVFoundationScreenInputConfiguration {
    MDKAVFoundationScreenInputConfiguration(
        minFrameDuration: MDKFrameDuration(for: configuration.frameRate),
        capturesCursor: false,
        capturesMouseClicks: false
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
        let screenInputConfiguration = makeMDKAVFoundationScreenInputConfiguration(for: configuration)
        screenInput.minFrameDuration = screenInputConfiguration.minFrameDuration
        screenInput.capturesCursor = screenInputConfiguration.capturesCursor
        screenInput.capturesMouseClicks = screenInputConfiguration.capturesMouseClicks

        let session = AVCaptureSession()
        guard session.canAddInput(screenInput) else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }
        session.addInput(screenInput)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: configuration.pixelFormat),
            kCVPixelBufferWidthKey as String: NSNumber(value: configuration.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: configuration.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        ]
        output.alwaysDiscardsLateVideoFrames = true
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
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            surfaceID = IOSurfaceGetID(surface)
        } else {
            surfaceID = 0
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
                pixelFormat: pixelFormat
            )
        )
    }
}
