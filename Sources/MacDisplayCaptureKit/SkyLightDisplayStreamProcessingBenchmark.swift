import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import MacDisplayKitObjCShim

public struct MDKSkyLightDisplayStreamProcessingBenchmarkResult: Codable, Equatable, Sendable {
    public static let realtimeFloorFrameRate: Double = 60.0

    public let displayID: UInt32
    public let status: Int32
    public let stopStatus: Int32
    public let processingMode: MDKCaptureBenchmarkProcessingMode
    public let videoEncoderCodec: MDKVideoEncoderCodec?
    public let sampleDuration: TimeInterval
    public let callbackCount: UInt64
    public let completeFrameCount: UInt64
    public let observedFrameRate: Double
    public let processedFrameCount: UInt64
    public let processingFailureCount: UInt64
    public let processingErrorHistogram: [String: Int]
    public let processedFrameRate: Double
    public let processedFrameRatio: Double
    public let outputCallbackCount: UInt64?
    public let completedOutputFrameCount: UInt64?
    public let completedOutputFrameRate: Double?
    public let completedOutputFrameRatio: Double?
    public let outputCallbackStatusHistogram: [String: Int]?
    public let outputCallbackLatencyHistogram: [String: Int]?
    public let minOutputCallbackLatencyMilliseconds: Double?
    public let maxOutputCallbackLatencyMilliseconds: Double?
    public let requestedMinimumFrameTime: Double
    public let requestedQueueDepth: Int
    public let requestedShowCursor: Bool
    public let surfaceWidth: Int
    public let surfaceHeight: Int
    public let pixelFormat: UInt32
    public let intervalCount: Int
    public let minIntervalMilliseconds: Double?
    public let maxIntervalMilliseconds: Double?
    public let intervalHistogram: [String: Int]
    public let stallCountOver16Milliseconds: Int
    public let stallCountOver33Milliseconds: Int
    public let stallCountOver100Milliseconds: Int
    public let cadenceClassification: String
    public let frameStatusHistogram: [String: Int]
    public let notes: [String]

    public var effectiveOutputFrameRate: Double {
        completedOutputFrameRate ?? processedFrameRate
    }

    public var meetsRealtimeFloor: Bool {
        effectiveOutputFrameRate >= Self.realtimeFloorFrameRate
    }

    public var meets120LikeTarget: Bool {
        cadenceClassification == "120hz-like" && effectiveOutputFrameRate >= 108.0
    }

    public func appendingNotes(_ additionalNotes: [String]) -> Self {
        guard !additionalNotes.isEmpty else {
            return self
        }

        return Self(
            displayID: displayID,
            status: status,
            stopStatus: stopStatus,
            processingMode: processingMode,
            videoEncoderCodec: videoEncoderCodec,
            sampleDuration: sampleDuration,
            callbackCount: callbackCount,
            completeFrameCount: completeFrameCount,
            observedFrameRate: observedFrameRate,
            processedFrameCount: processedFrameCount,
            processingFailureCount: processingFailureCount,
            processingErrorHistogram: processingErrorHistogram,
            processedFrameRate: processedFrameRate,
            processedFrameRatio: processedFrameRatio,
            outputCallbackCount: outputCallbackCount,
            completedOutputFrameCount: completedOutputFrameCount,
            completedOutputFrameRate: completedOutputFrameRate,
            completedOutputFrameRatio: completedOutputFrameRatio,
            outputCallbackStatusHistogram: outputCallbackStatusHistogram,
            outputCallbackLatencyHistogram: outputCallbackLatencyHistogram,
            minOutputCallbackLatencyMilliseconds: minOutputCallbackLatencyMilliseconds,
            maxOutputCallbackLatencyMilliseconds: maxOutputCallbackLatencyMilliseconds,
            requestedMinimumFrameTime: requestedMinimumFrameTime,
            requestedQueueDepth: requestedQueueDepth,
            requestedShowCursor: requestedShowCursor,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            pixelFormat: pixelFormat,
            intervalCount: intervalCount,
            minIntervalMilliseconds: minIntervalMilliseconds,
            maxIntervalMilliseconds: maxIntervalMilliseconds,
            intervalHistogram: intervalHistogram,
            stallCountOver16Milliseconds: stallCountOver16Milliseconds,
            stallCountOver33Milliseconds: stallCountOver33Milliseconds,
            stallCountOver100Milliseconds: stallCountOver100Milliseconds,
            cadenceClassification: cadenceClassification,
            frameStatusHistogram: frameStatusHistogram,
            notes: notes + additionalNotes
        )
    }
}

private final class MDKSkyLightDisplayStreamProcessingRecorder {
    var callbackCount: UInt64 = 0
    var completeFrameCount: UInt64 = 0
    var processedFrameCount: UInt64 = 0
    var processingFailureCount: UInt64 = 0
    var processingErrorHistogram: [String: Int] = [:]
    var frameStatusHistogram: [String: Int] = [:]
    var surfaceWidth: Int = 0
    var surfaceHeight: Int = 0
    var pixelFormat: UInt32 = 0
    var nextSequenceNumber: UInt64 = 0
    var lastDisplayTime: UInt64?
    var intervalCount: Int = 0
    var minIntervalMilliseconds: Double?
    var maxIntervalMilliseconds: Double?
    var intervalHistogram: [String: Int] = [:]
    var stallCountOver16Milliseconds: Int = 0
    var stallCountOver33Milliseconds: Int = 0
    var stallCountOver100Milliseconds: Int = 0
    var count120Like: Int = 0
    var count60Like: Int = 0
    private lazy var timebaseFactorMilliseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000.0
    }()

    func record(
        status: CGDisplayStreamFrameStatus,
        displayTime: UInt64,
        frameSurface: IOSurfaceRef?,
        processor: any MDKCaptureFrameProcessing
    ) {
        callbackCount += 1
        frameStatusHistogram[describe(status: status), default: 0] += 1

        guard status == .frameComplete, let frameSurface else {
            return
        }

        completeFrameCount += 1
        let surfaceID = IOSurfaceGetID(frameSurface)
        let width = IOSurfaceGetWidth(frameSurface)
        let height = IOSurfaceGetHeight(frameSurface)
        let pixelFormat = IOSurfaceGetPixelFormat(frameSurface)
        let planeCount = max(Int(IOSurfaceGetPlaneCount(frameSurface)), 0)
        if surfaceWidth == 0 {
            surfaceWidth = width
        }
        if surfaceHeight == 0 {
            surfaceHeight = height
        }
        if self.pixelFormat == 0 {
            self.pixelFormat = pixelFormat
        }
        recordInterval(for: displayTime)

        let frame = MDKCaptureFrame(
            sequenceNumber: nextSequenceNumber,
            displayTime: displayTime,
            surfaceID: surfaceID,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            surface: MDKCaptureSurface(
                ioSurface: frameSurface,
                id: surfaceID,
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                planeCount: planeCount
            )
        )
        nextSequenceNumber += 1

        do {
            try processor.process(frame: frame)
            processedFrameCount += 1
        } catch {
            processingFailureCount += 1
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            processingErrorHistogram[errorDescription, default: 0] += 1
        }
    }

    func makeResult(
        displayID: UInt32,
        status: Int32,
        stopStatus: Int32,
        processingMode: MDKCaptureBenchmarkProcessingMode,
        sampleDuration: TimeInterval,
        requestedMinimumFrameTime: Double,
        requestedQueueDepth: Int,
        requestedShowCursor: Bool,
        requestedPixelFormat: UInt32,
        processingSummary: MDKCaptureFrameProcessingSummary?
    ) -> MDKSkyLightDisplayStreamProcessingBenchmarkResult {
        let observedFrameRate = sampleDuration > 0 ? Double(completeFrameCount) / sampleDuration : 0
        let summaryProcessedFrameCount = processingSummary?.processedFrameCount ?? processedFrameCount
        let summaryProcessingFailureCount = processingSummary?.processingFailureCount ?? processingFailureCount
        let summaryProcessingErrorHistogram = processingSummary?.processingErrorHistogram ?? processingErrorHistogram
        let summaryOutputCallbackCount = processingSummary?.outputCallbackCount
        let summaryCompletedOutputFrameCount = processingSummary?.completedOutputFrameCount
        let summaryOutputCallbackStatusHistogram = processingSummary?.outputCallbackStatusHistogram
        let summaryOutputCallbackLatencyHistogram = processingSummary?.outputCallbackLatencyHistogram
        let summaryMinOutputCallbackLatencyMilliseconds = processingSummary?.minOutputCallbackLatencyMilliseconds
        let summaryMaxOutputCallbackLatencyMilliseconds = processingSummary?.maxOutputCallbackLatencyMilliseconds
        let processedFrameRate = sampleDuration > 0 ? Double(summaryProcessedFrameCount) / sampleDuration : 0
        let processedFrameRatio = completeFrameCount > 0 ? Double(summaryProcessedFrameCount) / Double(completeFrameCount) : 0
        let completedOutputFrameRate = summaryCompletedOutputFrameCount.map {
            sampleDuration > 0 ? Double($0) / sampleDuration : 0
        }
        let completedOutputFrameRatio = summaryCompletedOutputFrameCount.map {
            summaryProcessedFrameCount > 0 ? Double($0) / Double(summaryProcessedFrameCount) : 0
        }

        var notes = [
            "Uses raw SkyLight SLDisplayStreamCreateWithDispatchQueue instead of replayd-backed SCStream.",
            "Raw frame processing path uses mode=\(processingMode.rawValue).",
            String(format: "requestedMinimumFrameTime=%.6f", requestedMinimumFrameTime),
            "requestedQueueDepth=\(requestedQueueDepth)",
            "requestedShowCursor=\(requestedShowCursor ? "true" : "false")",
            String(format: "requestedPixelFormat=0x%08X", requestedPixelFormat)
        ]
        if completeFrameCount == 0 {
            notes.append("The stream did not deliver any complete IOSurface-backed frames during the sample window.")
        }
        if summaryProcessingFailureCount > 0 {
            notes.append("processingFailureCount=\(summaryProcessingFailureCount)")
            notes.append("processingErrors=\(summaryProcessingErrorHistogram)")
        }
        if let summaryOutputCallbackCount {
            notes.append("outputCallbackCount=\(summaryOutputCallbackCount)")
        }
        if let processingSummary {
            notes.append(contentsOf: processingSummary.notes)
        }

        return MDKSkyLightDisplayStreamProcessingBenchmarkResult(
            displayID: displayID,
            status: status,
            stopStatus: stopStatus,
            processingMode: processingMode,
            videoEncoderCodec: processingMode.videoEncoderCodec,
            sampleDuration: sampleDuration,
            callbackCount: callbackCount,
            completeFrameCount: completeFrameCount,
            observedFrameRate: observedFrameRate,
            processedFrameCount: summaryProcessedFrameCount,
            processingFailureCount: summaryProcessingFailureCount,
            processingErrorHistogram: summaryProcessingErrorHistogram,
            processedFrameRate: processedFrameRate,
            processedFrameRatio: processedFrameRatio,
            outputCallbackCount: summaryOutputCallbackCount,
            completedOutputFrameCount: summaryCompletedOutputFrameCount,
            completedOutputFrameRate: completedOutputFrameRate,
            completedOutputFrameRatio: completedOutputFrameRatio,
            outputCallbackStatusHistogram: summaryOutputCallbackStatusHistogram,
            outputCallbackLatencyHistogram: summaryOutputCallbackLatencyHistogram,
            minOutputCallbackLatencyMilliseconds: summaryMinOutputCallbackLatencyMilliseconds,
            maxOutputCallbackLatencyMilliseconds: summaryMaxOutputCallbackLatencyMilliseconds,
            requestedMinimumFrameTime: requestedMinimumFrameTime,
            requestedQueueDepth: requestedQueueDepth,
            requestedShowCursor: requestedShowCursor,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            pixelFormat: pixelFormat == 0 ? kCVPixelFormatType_32BGRA : pixelFormat,
            intervalCount: intervalCount,
            minIntervalMilliseconds: minIntervalMilliseconds,
            maxIntervalMilliseconds: maxIntervalMilliseconds,
            intervalHistogram: intervalHistogram,
            stallCountOver16Milliseconds: stallCountOver16Milliseconds,
            stallCountOver33Milliseconds: stallCountOver33Milliseconds,
            stallCountOver100Milliseconds: stallCountOver100Milliseconds,
            cadenceClassification: classifyCadence(),
            frameStatusHistogram: frameStatusHistogram,
            notes: notes
        )
    }

    private func describe(status: CGDisplayStreamFrameStatus) -> String {
        switch status {
        case .frameBlank:
            return "frame-blank"
        case .frameComplete:
            return "frame-complete"
        case .frameIdle:
            return "frame-idle"
        case .stopped:
            return "stopped"
        @unknown default:
            return "status-\(status.rawValue)"
        }
    }

    private func recordInterval(for displayTime: UInt64) {
        defer {
            lastDisplayTime = displayTime
        }

        guard let lastDisplayTime else {
            return
        }

        let intervalMilliseconds = Double(displayTime &- lastDisplayTime) * timebaseFactorMilliseconds
        intervalCount += 1
        minIntervalMilliseconds = min(minIntervalMilliseconds ?? intervalMilliseconds, intervalMilliseconds)
        maxIntervalMilliseconds = max(maxIntervalMilliseconds ?? intervalMilliseconds, intervalMilliseconds)

        let rounded = (intervalMilliseconds * 10.0).rounded() / 10.0
        intervalHistogram[String(format: "%.1fms", rounded), default: 0] += 1

        if intervalMilliseconds > 16.7 {
            stallCountOver16Milliseconds += 1
        }
        if intervalMilliseconds > 33.3 {
            stallCountOver33Milliseconds += 1
        }
        if intervalMilliseconds > 100.0 {
            stallCountOver100Milliseconds += 1
        }
        if intervalMilliseconds <= 10.0 {
            count120Like += 1
        }
        if intervalMilliseconds >= 12.0 && intervalMilliseconds <= 21.0 {
            count60Like += 1
        }
    }

    private func classifyCadence() -> String {
        guard intervalCount >= 2 else {
            return "insufficient-data"
        }

        let total = intervalCount
        if Double(count120Like) / Double(total) >= 0.7 {
            return "120hz-like"
        }
        if Double(count60Like) / Double(total) >= 0.7 {
            return "60hz-like"
        }
        return "coalesced-or-mixed"
    }
}

public enum MDKSkyLightDisplayStreamProcessingBenchmark {
    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        configuration: MDKSkyLightDisplayStreamConfiguration,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> MDKSkyLightDisplayStreamProcessingBenchmarkResult {
        try run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            minimumFrameTime: configuration.resolvedMinimumFrameTime,
            queueDepth: configuration.resolvedQueueDepth,
            showCursor: configuration.tuning.showCursor,
            outputWidth: configuration.resolvedOutputWidth == 0 ? nil : configuration.resolvedOutputWidth,
            outputHeight: configuration.resolvedOutputHeight == 0 ? nil : configuration.resolvedOutputHeight,
            pixelFormat: configuration.resolvedPixelFormatOverride == 0 ? nil : configuration.resolvedPixelFormatOverride,
            processingMode: processingMode
        )
    }

    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        minimumFrameTime: Double,
        queueDepth: Int,
        showCursor: Bool,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        pixelFormat: UInt32? = nil,
        targetFrameRate: Int? = nil,
        processingMode: MDKCaptureBenchmarkProcessingMode
    ) throws -> MDKSkyLightDisplayStreamProcessingBenchmarkResult {
        let requestedMinimumFrameTime = max(minimumFrameTime, 0)
        let requestedQueueDepth = max(queueDepth, 1)
        let recorder = MDKSkyLightDisplayStreamProcessingRecorder()
        let targetFrameRate: Int = {
            if let targetFrameRate {
                return max(targetFrameRate, 1)
            }
            if requestedMinimumFrameTime > 0 {
                return max(Int((1.0 / requestedMinimumFrameTime).rounded()), 1)
            }
            return 120
        }()
        let processor = try MDKCaptureFrameProcessingFactory.make(
            processingMode: processingMode,
            targetFrameRate: targetFrameRate
        )
        let resolvedPixelFormat: OSType = OSType(pixelFormat ?? kCVPixelFormatType_32BGRA)
        let resolvedOutputWidth = UInt(max(outputWidth ?? 0, 0))
        let resolvedOutputHeight = UInt(max(outputHeight ?? 0, 0))

        let session = MDKShimSkyLightDisplayStreamSession(
            displayID: UInt(displayID),
            minimumFrameTime: requestedMinimumFrameTime,
            queueDepth: requestedQueueDepth,
            showCursor: showCursor,
            outputWidth: resolvedOutputWidth,
            outputHeight: resolvedOutputHeight,
            pixelFormat: resolvedPixelFormat
        ) { status, displayTime, frameSurface in
            recorder.record(
                status: status,
                displayTime: displayTime,
                frameSurface: frameSurface,
                processor: processor
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        try session.start()

        Thread.sleep(forTimeInterval: max(sampleDuration, 0.001))
        let stopStatus = session.stop()
        let elapsed = max(ProcessInfo.processInfo.systemUptime - startedAt, 0)
        let processingSummary = processor.finalize()

        return recorder.makeResult(
            displayID: displayID,
            status: 0,
            stopStatus: stopStatus,
            processingMode: processingMode,
            sampleDuration: elapsed,
            requestedMinimumFrameTime: requestedMinimumFrameTime,
            requestedQueueDepth: requestedQueueDepth,
            requestedShowCursor: showCursor,
            requestedPixelFormat: UInt32(resolvedPixelFormat),
            processingSummary: processingSummary
        )
    }
}
