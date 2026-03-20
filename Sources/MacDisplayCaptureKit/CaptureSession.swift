import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

public struct MDKCaptureFrame: Sendable, Equatable {
    public let sequenceNumber: UInt64
    public let displayTime: UInt64
    public let surfaceID: UInt32
    public let width: Int
    public let height: Int
    public let pixelFormat: UInt32
}

public struct MDKCaptureSessionStatistics: Sendable, Equatable {
    public let callbackCount: UInt64
    public let deliveredFrameCount: UInt64
    public let skippedFrameCount: UInt64
    public let lastDisplayTime: UInt64

    public static let zero = MDKCaptureSessionStatistics(
        callbackCount: 0,
        deliveredFrameCount: 0,
        skippedFrameCount: 0,
        lastDisplayTime: 0
    )
}

public enum MDKCaptureSessionError: Error, LocalizedError, Equatable {
    case unsupportedBackend(MDKCaptureBackend)
    case alreadyRunning
    case streamCreationFailed(displayID: UInt32)
    case streamStartFailed(displayID: UInt32, errorCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let backend):
            return "Capture backend \(backend.rawValue) is not startable in MacDisplayKit yet."
        case .alreadyRunning:
            return "Capture session is already running."
        case .streamCreationFailed(let displayID):
            return "Unable to create a CGDisplayStream for display \(displayID)."
        case .streamStartFailed(let displayID, let errorCode):
            return "Unable to start the CGDisplayStream for display \(displayID) (CGError \(errorCode))."
        }
    }
}

public typealias MDKCaptureFrameHandler = @Sendable (MDKCaptureFrame) -> Void

public final class MDKCaptureSession {
    public let configuration: MDKCaptureConfiguration

    private let driver: any MDKCaptureSessionDriver

    internal init(configuration: MDKCaptureConfiguration, driver: any MDKCaptureSessionDriver) {
        self.configuration = configuration
        self.driver = driver
    }

    public var backend: MDKCaptureBackend {
        driver.backend
    }

    public var isRunning: Bool {
        driver.isRunning
    }

    public var statistics: MDKCaptureSessionStatistics {
        driver.statistics
    }

    public func start(frameHandler: @escaping MDKCaptureFrameHandler) throws {
        try driver.start(frameHandler: frameHandler)
    }

    public func stop() {
        driver.stop()
    }

    deinit {
        stop()
    }
}

public enum MDKCaptureSessionFactory {
    public static func makeSession(configuration: MDKCaptureConfiguration) throws -> MDKCaptureSession {
        switch configuration.backend {
        case .cgDisplayStream:
            return MDKCaptureSession(
                configuration: configuration,
                driver: MDKCGDisplayStreamCaptureDriver(configuration: configuration)
            )
        case .avFoundation:
            throw MDKCaptureSessionError.unsupportedBackend(.avFoundation)
        }
    }
}

protocol MDKCaptureSessionDriver: AnyObject {
    var backend: MDKCaptureBackend { get }
    var isRunning: Bool { get }
    var statistics: MDKCaptureSessionStatistics { get }

    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws
    func stop()
}

private final class MDKCGDisplayStreamCaptureDriver: MDKCaptureSessionDriver {
    let backend: MDKCaptureBackend = .cgDisplayStream

    private let configuration: MDKCaptureConfiguration
    private let queue: DispatchQueue
    private let stateLock = NSLock()

    private var stream: CGDisplayStream?
    private var running = false
    private var nextSequenceNumber: UInt64 = 0
    private var stats = MDKCaptureSessionStatistics.zero

    init(configuration: MDKCaptureConfiguration) {
        self.configuration = configuration
        self.queue = DispatchQueue(
            label: "com.skyline23.MacDisplayKit.capture.cgdisplaystream.\(configuration.displayID)"
        )
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var statistics: MDKCaptureSessionStatistics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stats
    }

    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            throw MDKCaptureSessionError.alreadyRunning
        }
        stateLock.unlock()

        let properties = [
            CGDisplayStream.showCursor: kCFBooleanTrue as Any
        ] as NSDictionary as CFDictionary

        let stream = CGDisplayStream(
            dispatchQueueDisplay: configuration.displayID,
            outputWidth: max(configuration.width, 1),
            outputHeight: max(configuration.height, 1),
            pixelFormat: Int32(bitPattern: configuration.pixelFormat),
            properties: properties,
            queue: queue,
            handler: { [weak self] status, displayTime, surface, _ in
                self?.handleFrame(
                    status: status,
                    displayTime: displayTime,
                    surface: surface,
                    frameHandler: frameHandler
                )
            }
        )

        guard let stream else {
            throw MDKCaptureSessionError.streamCreationFailed(displayID: configuration.displayID)
        }

        let startError = stream.start()
        guard startError == .success else {
            throw MDKCaptureSessionError.streamStartFailed(
                displayID: configuration.displayID,
                errorCode: Int32(startError.rawValue)
            )
        }

        stateLock.lock()
        self.stream = stream
        self.running = true
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        let stream = self.stream
        self.stream = nil
        self.running = false
        stateLock.unlock()

        guard let stream else {
            return
        }

        _ = stream.stop()
    }

    private func handleFrame(
        status: CGDisplayStreamFrameStatus,
        displayTime: UInt64,
        surface: IOSurfaceRef?,
        frameHandler: @escaping MDKCaptureFrameHandler
    ) {
        stateLock.lock()
        let callbackCount = stats.callbackCount + 1
        var deliveredFrameCount = stats.deliveredFrameCount
        var skippedFrameCount = stats.skippedFrameCount
        var nextSequenceNumber = self.nextSequenceNumber

        guard status == .frameComplete, let surface else {
            skippedFrameCount += 1
            stats = MDKCaptureSessionStatistics(
                callbackCount: callbackCount,
                deliveredFrameCount: deliveredFrameCount,
                skippedFrameCount: skippedFrameCount,
                lastDisplayTime: displayTime
            )
            stateLock.unlock()
            return
        }

        deliveredFrameCount += 1
        nextSequenceNumber += 1
        self.nextSequenceNumber = nextSequenceNumber
        stats = MDKCaptureSessionStatistics(
            callbackCount: callbackCount,
            deliveredFrameCount: deliveredFrameCount,
            skippedFrameCount: skippedFrameCount,
            lastDisplayTime: displayTime
        )
        stateLock.unlock()

        frameHandler(
            MDKCaptureFrame(
                sequenceNumber: nextSequenceNumber,
                displayTime: displayTime,
                surfaceID: IOSurfaceGetID(surface),
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface),
                pixelFormat: IOSurfaceGetPixelFormat(surface)
            )
        )
    }
}
