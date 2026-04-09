import CoreGraphics
import Foundation
import IOSurface
import MacDisplayKitObjCShim

public final class MDKSkyLightDisplayStreamSession: @unchecked Sendable {
    public let displayID: UInt32
    public let configuration: MDKSkyLightDisplayStreamConfiguration

    private let driver: MDKSkyLightDisplayStreamSessionDriver

    public init(
        displayID: UInt32,
        configuration: MDKSkyLightDisplayStreamConfiguration = .panelNative()
    ) {
        self.displayID = displayID
        self.configuration = configuration
        self.driver = MDKSkyLightDisplayStreamSessionDriver(
            displayID: displayID,
            minimumFrameTime: 0,
            configuration: configuration
        )
    }

    public var isRunning: Bool {
        get async {
            await driver.isRunning
        }
    }

    public var statistics: MDKCaptureSessionStatistics {
        get async {
            await driver.statistics
        }
    }

    public func start(frameHandler: @escaping MDKCaptureFrameHandler) async throws {
        try await driver.start(frameHandler: frameHandler)
    }

    public func stop() async {
        await driver.stop()
    }
}

private actor MDKSkyLightDisplayStreamSessionDriver {
    let displayID: UInt32
    let minimumFrameTime: Double
    let configuration: MDKSkyLightDisplayStreamConfiguration

    private var shimSession: MDKShimSkyLightDisplayStreamSession?
    private var nextSequenceNumber: UInt64 = 0
    private var stats: MDKCaptureSessionStatistics = .zero
    private var running = false

    init(
        displayID: UInt32,
        minimumFrameTime: Double,
        configuration: MDKSkyLightDisplayStreamConfiguration
    ) {
        self.displayID = displayID
        self.minimumFrameTime = minimumFrameTime
        self.configuration = configuration
    }

    var isRunning: Bool {
        running
    }

    var statistics: MDKCaptureSessionStatistics {
        stats
    }

    func start(frameHandler: @escaping MDKCaptureFrameHandler) throws {
        guard !running else {
            throw MDKCaptureSessionError.alreadyRunning
        }

        let shimSession = MDKShimSkyLightDisplayStreamSession(
            displayID: UInt(displayID),
            minimumFrameTime: minimumFrameTime,
            queueDepth: configuration.resolvedQueueDepth,
            showCursor: configuration.resolvedShowCursor,
            outputWidth: UInt(configuration.resolvedOutputWidth),
            outputHeight: UInt(configuration.resolvedOutputHeight),
            pixelFormat: configuration.resolvedPixelFormatOverride,
            yCbCrMatrix: configuration.resolvedYCbCrMatrixOverride
        ) { [weak self] status, displayTime, frameSurface in
            guard let self else {
                return
            }
            let deliveredFrame: MDKCaptureFrame?
            if status == .frameComplete, let frameSurface {
                let surface = MDKCaptureSurface(ioSurface: frameSurface)
                deliveredFrame = MDKCaptureFrame(
                    sequenceNumber: 0,
                    displayTime: displayTime,
                    surfaceID: surface.id,
                    width: surface.width,
                    height: surface.height,
                    pixelFormat: surface.pixelFormat,
                    surface: surface
                )
            } else {
                deliveredFrame = nil
            }
            Task {
                await self.handleFrame(
                    displayTime: displayTime,
                    deliveredFrame: deliveredFrame,
                    frameHandler: frameHandler
                )
            }
        }

        try shimSession.start()
        self.shimSession = shimSession
        running = true
    }

    func stop() {
        guard let shimSession else {
            running = false
            return
        }

        _ = shimSession.stop()
        self.shimSession = nil
        running = false
    }

    private func handleFrame(
        displayTime: UInt64,
        deliveredFrame: MDKCaptureFrame?,
        frameHandler: @escaping MDKCaptureFrameHandler
    ) {
        stats = MDKCaptureSessionStatistics(
            callbackCount: stats.callbackCount + 1,
            deliveredFrameCount: stats.deliveredFrameCount,
            skippedFrameCount: stats.skippedFrameCount,
            lastDisplayTime: displayTime
        )

        guard let deliveredFrame else {
            stats = MDKCaptureSessionStatistics(
                callbackCount: stats.callbackCount,
                deliveredFrameCount: stats.deliveredFrameCount,
                skippedFrameCount: stats.skippedFrameCount + 1,
                lastDisplayTime: displayTime
            )
            return
        }

        let frame = MDKCaptureFrame(
            sequenceNumber: nextSequenceNumber,
            displayTime: deliveredFrame.displayTime,
            surfaceID: deliveredFrame.surfaceID,
            width: deliveredFrame.width,
            height: deliveredFrame.height,
            pixelFormat: deliveredFrame.pixelFormat,
            surface: deliveredFrame.surface
        )
        nextSequenceNumber += 1

        stats = MDKCaptureSessionStatistics(
            callbackCount: stats.callbackCount,
            deliveredFrameCount: stats.deliveredFrameCount + 1,
            skippedFrameCount: stats.skippedFrameCount,
            lastDisplayTime: displayTime
        )
        frameHandler(frame)
    }
}
