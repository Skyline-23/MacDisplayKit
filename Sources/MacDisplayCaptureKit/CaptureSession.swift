import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

func MDKDisplayLogicalSize(displayID: CGDirectDisplayID) -> CGSize {
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

func MDKDisplayRefreshRate(displayID: CGDirectDisplayID) -> Double? {
    guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
        return nil
    }

    let refreshRate = displayMode.refreshRate
    guard refreshRate > 1 else {
        return nil
    }

    return refreshRate
}

struct MDKCGDisplayStreamConfiguration: Equatable {
    let minimumFrameTime: TimeInterval
    let sourceRect: CGRect
    let destinationRect: CGRect
    let preserveAspectRatio: Bool
    let queueDepth: Int
    let yCbCrMatrix: CFString?
}

func makeMDKCGDisplayStreamConfiguration(
    for configuration: MDKCaptureConfiguration,
    logicalSize: CGSize
) -> MDKCGDisplayStreamConfiguration {
    let frameTimeInSeconds: Float
    if configuration.frameRate <= 0 || configuration.frameRate > 60 {
        frameTimeInSeconds = 0
    } else {
        frameTimeInSeconds = 1.0 / Float(configuration.frameRate)
    }

    let yCbCrMatrix: CFString?
    switch configuration.pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        yCbCrMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    default:
        yCbCrMatrix = nil
    }

    return MDKCGDisplayStreamConfiguration(
        minimumFrameTime: TimeInterval(frameTimeInSeconds),
        sourceRect: CGRect(origin: .zero, size: logicalSize),
        destinationRect: CGRect(
            x: 0,
            y: 0,
            width: configuration.width,
            height: configuration.height
        ),
        preserveAspectRatio: false,
        queueDepth: configuration.frameRate > 60 ? 2 : 3,
        yCbCrMatrix: yCbCrMatrix
    )
}

func MDKDisplayStreamProperties(
    for configuration: MDKCaptureConfiguration,
    logicalSize: CGSize
) -> CFDictionary {
    let streamConfiguration = makeMDKCGDisplayStreamConfiguration(
        for: configuration,
        logicalSize: logicalSize
    )

    var properties: [String: Any] = [
        CGDisplayStream.showCursor as String: false,
        CGDisplayStream.minimumFrameTime as String: NSNumber(value: streamConfiguration.minimumFrameTime),
        CGDisplayStream.sourceRect as String: CGRectCreateDictionaryRepresentation(streamConfiguration.sourceRect),
        CGDisplayStream.destinationRect as String: CGRectCreateDictionaryRepresentation(streamConfiguration.destinationRect),
        CGDisplayStream.preserveAspectRatio as String: NSNumber(value: streamConfiguration.preserveAspectRatio),
        CGDisplayStream.queueDepth as String: NSNumber(value: streamConfiguration.queueDepth),
    ]

    if let yCbCrMatrix = streamConfiguration.yCbCrMatrix {
        properties[CGDisplayStream.yCbCrMatrix as String] = yCbCrMatrix
    }

    return properties as NSDictionary as CFDictionary
}

public struct MDKCaptureFrame: Sendable, Equatable {
    public let sequenceNumber: UInt64
    public let displayTime: UInt64
    public let surfaceID: UInt32
    public let width: Int
    public let height: Int
    public let pixelFormat: UInt32
    public let surface: MDKCaptureSurface?
    public let cursorOverlaySample: MDKCursorOverlaySample?
    public let sourceCaptureDurationNanoseconds: UInt64?
    public let sourceCursorCompositeDurationNanoseconds: UInt64?

    public init(
        sequenceNumber: UInt64,
        displayTime: UInt64,
        surfaceID: UInt32,
        width: Int,
        height: Int,
        pixelFormat: UInt32,
        surface: MDKCaptureSurface? = nil,
        cursorOverlaySample: MDKCursorOverlaySample? = nil,
        sourceCaptureDurationNanoseconds: UInt64? = nil,
        sourceCursorCompositeDurationNanoseconds: UInt64? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.displayTime = displayTime
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.surface = surface
        self.cursorOverlaySample = cursorOverlaySample
        self.sourceCaptureDurationNanoseconds = sourceCaptureDurationNanoseconds
        self.sourceCursorCompositeDurationNanoseconds = sourceCursorCompositeDurationNanoseconds
    }
}

public struct MDKCursorOverlaySample: Sendable, Equatable {
    public let surface: MDKCaptureSurface
    public let rect: CGRect
    public let isVerticallyFlipped: Bool

    public init(
        surface: MDKCaptureSurface,
        rect: CGRect,
        isVerticallyFlipped: Bool = false
    ) {
        self.surface = surface
        self.rect = rect
        self.isVerticallyFlipped = isVerticallyFlipped
    }
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

    public func delta(since baseline: MDKCaptureSessionStatistics) -> MDKCaptureSessionStatistics {
        MDKCaptureSessionStatistics(
            callbackCount: callbackCount &- baseline.callbackCount,
            deliveredFrameCount: deliveredFrameCount &- baseline.deliveredFrameCount,
            skippedFrameCount: skippedFrameCount &- baseline.skippedFrameCount,
            lastDisplayTime: lastDisplayTime
        )
    }
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
            return MDKCaptureSession(
                configuration: configuration,
                driver: MDKAVFoundationCaptureDriver(configuration: configuration)
            )
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

        let logicalSize = MDKDisplayLogicalSize(displayID: configuration.displayID)
        let properties = MDKDisplayStreamProperties(
            for: configuration,
            logicalSize: logicalSize
        )

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
                pixelFormat: IOSurfaceGetPixelFormat(surface),
                surface: MDKCaptureSurface(ioSurface: surface)
            )
        )
    }
}
