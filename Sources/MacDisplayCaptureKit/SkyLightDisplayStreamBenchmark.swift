import CoreVideo
import Foundation
import MacDisplayKitObjCShim

public enum MDKSkyLightDisplayStreamPixelFormat: String, CaseIterable, Codable, Sendable {
    case bgra
    case biPlanar420VideoRange = "420v"
    case biPlanar420FullRange = "420f"
    case biPlanar42010VideoRange = "x420"
    case biPlanar42010FullRange = "xf20"

    public var pixelFormat: UInt32 {
        switch self {
        case .bgra:
            return kCVPixelFormatType_32BGRA
        case .biPlanar420VideoRange:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .biPlanar420FullRange:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .biPlanar42010VideoRange:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .biPlanar42010FullRange:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }
}

public struct MDKSkyLightDisplayStreamBenchmarkResult: Codable, Equatable, Sendable {
    public static let realtimeFloorFrameRate: Double = 60.0

    public let displayID: UInt32
    public let status: Int32
    public let stopStatus: Int32
    public let sampleDuration: TimeInterval
    public let callbackCount: UInt64
    public let completeFrameCount: UInt64
    public let observedFrameRate: Double
    public let requested120LikeProperties: Bool
    public let requestedMinimumFrameTime: Double
    public let requestedQueueDepth: Int
    public let requestedShowCursor: Bool
    public let appliedPropertyCount: Int
    public let surfaceWidth: Int
    public let surfaceHeight: Int
    public let pixelFormat: UInt32
    public let intervalCount: Int
    public let minIntervalMilliseconds: Double?
    public let maxIntervalMilliseconds: Double?
    public let stallCountOver16Milliseconds: Int
    public let stallCountOver33Milliseconds: Int
    public let stallCountOver100Milliseconds: Int
    public let longGapRatioOver16Milliseconds: Double
    public let longGapRatioOver33Milliseconds: Double
    public let longGapRatioOver100Milliseconds: Double
    public let intervalHistogram: [String: Int]
    public let cadenceClassification: String
    public let frameStatusHistogram: [String: Int]
    public let notes: [String]

    public var meetsRealtimeFloor: Bool {
        observedFrameRate >= Self.realtimeFloorFrameRate
    }

    public init(
        displayID: UInt32,
        status: Int32,
        stopStatus: Int32,
        sampleDuration: TimeInterval,
        callbackCount: UInt64,
        completeFrameCount: UInt64,
        observedFrameRate: Double,
        requested120LikeProperties: Bool,
        requestedMinimumFrameTime: Double,
        requestedQueueDepth: Int,
        requestedShowCursor: Bool,
        appliedPropertyCount: Int,
        surfaceWidth: Int,
        surfaceHeight: Int,
        pixelFormat: UInt32,
        intervalCount: Int,
        minIntervalMilliseconds: Double?,
        maxIntervalMilliseconds: Double?,
        stallCountOver16Milliseconds: Int = 0,
        stallCountOver33Milliseconds: Int = 0,
        stallCountOver100Milliseconds: Int = 0,
        longGapRatioOver16Milliseconds: Double = 0.0,
        longGapRatioOver33Milliseconds: Double = 0.0,
        longGapRatioOver100Milliseconds: Double = 0.0,
        intervalHistogram: [String: Int],
        cadenceClassification: String,
        frameStatusHistogram: [String: Int],
        notes: [String]
    ) {
        self.displayID = displayID
        self.status = status
        self.stopStatus = stopStatus
        self.sampleDuration = sampleDuration
        self.callbackCount = callbackCount
        self.completeFrameCount = completeFrameCount
        self.observedFrameRate = observedFrameRate
        self.requested120LikeProperties = requested120LikeProperties
        self.requestedMinimumFrameTime = requestedMinimumFrameTime
        self.requestedQueueDepth = requestedQueueDepth
        self.requestedShowCursor = requestedShowCursor
        self.appliedPropertyCount = appliedPropertyCount
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.pixelFormat = pixelFormat
        self.intervalCount = intervalCount
        self.minIntervalMilliseconds = minIntervalMilliseconds
        self.maxIntervalMilliseconds = maxIntervalMilliseconds
        self.stallCountOver16Milliseconds = stallCountOver16Milliseconds
        self.stallCountOver33Milliseconds = stallCountOver33Milliseconds
        self.stallCountOver100Milliseconds = stallCountOver100Milliseconds
        self.longGapRatioOver16Milliseconds = longGapRatioOver16Milliseconds
        self.longGapRatioOver33Milliseconds = longGapRatioOver33Milliseconds
        self.longGapRatioOver100Milliseconds = longGapRatioOver100Milliseconds
        self.intervalHistogram = intervalHistogram
        self.cadenceClassification = cadenceClassification
        self.frameStatusHistogram = frameStatusHistogram
        self.notes = notes
    }

    init(shimDictionary: NSDictionary) throws {
        guard
            let displayIDNumber = shimDictionary["displayID"] as? NSNumber,
            let statusNumber = shimDictionary["status"] as? NSNumber,
            let stopStatusNumber = shimDictionary["stopStatus"] as? NSNumber,
            let sampleDurationNumber = shimDictionary["sampleDuration"] as? NSNumber,
            let callbackCountNumber = shimDictionary["callbackCount"] as? NSNumber,
            let completeFrameCountNumber = shimDictionary["completeFrameCount"] as? NSNumber,
            let observedFrameRateNumber = shimDictionary["observedFrameRate"] as? NSNumber,
            let requested120LikePropertiesNumber = shimDictionary["requested120LikeProperties"] as? NSNumber,
            let requestedMinimumFrameTimeNumber = shimDictionary["requestedMinimumFrameTime"] as? NSNumber,
            let requestedQueueDepthNumber = shimDictionary["requestedQueueDepth"] as? NSNumber,
            let requestedShowCursorNumber = shimDictionary["requestedShowCursor"] as? NSNumber,
            let appliedPropertyCountNumber = shimDictionary["appliedPropertyCount"] as? NSNumber,
            let surfaceWidthNumber = shimDictionary["surfaceWidth"] as? NSNumber,
            let surfaceHeightNumber = shimDictionary["surfaceHeight"] as? NSNumber,
            let pixelFormatNumber = shimDictionary["pixelFormat"] as? NSNumber,
            let intervalCountNumber = shimDictionary["intervalCount"] as? NSNumber,
            let intervalHistogram = shimDictionary["intervalHistogram"] as? [String: NSNumber],
            let cadenceClassification = shimDictionary["cadenceClassification"] as? String,
            let frameStatusHistogram = shimDictionary["frameStatusHistogram"] as? [String: NSNumber],
            let notes = shimDictionary["notes"] as? [String]
        else {
            throw MDKPrivateCapturePrototypeProbeError.invalidShimPayload
        }

        self.init(
            displayID: displayIDNumber.uint32Value,
            status: statusNumber.int32Value,
            stopStatus: stopStatusNumber.int32Value,
            sampleDuration: sampleDurationNumber.doubleValue,
            callbackCount: callbackCountNumber.uint64Value,
            completeFrameCount: completeFrameCountNumber.uint64Value,
            observedFrameRate: observedFrameRateNumber.doubleValue,
            requested120LikeProperties: requested120LikePropertiesNumber.boolValue,
            requestedMinimumFrameTime: requestedMinimumFrameTimeNumber.doubleValue,
            requestedQueueDepth: requestedQueueDepthNumber.intValue,
            requestedShowCursor: requestedShowCursorNumber.boolValue,
            appliedPropertyCount: appliedPropertyCountNumber.intValue,
            surfaceWidth: surfaceWidthNumber.intValue,
            surfaceHeight: surfaceHeightNumber.intValue,
            pixelFormat: pixelFormatNumber.uint32Value,
            intervalCount: intervalCountNumber.intValue,
            minIntervalMilliseconds: (shimDictionary["minIntervalMilliseconds"] as? NSNumber)?.doubleValue,
            maxIntervalMilliseconds: (shimDictionary["maxIntervalMilliseconds"] as? NSNumber)?.doubleValue,
            stallCountOver16Milliseconds: (shimDictionary["stallCountOver16Milliseconds"] as? NSNumber)?.intValue ?? 0,
            stallCountOver33Milliseconds: (shimDictionary["stallCountOver33Milliseconds"] as? NSNumber)?.intValue ?? 0,
            stallCountOver100Milliseconds: (shimDictionary["stallCountOver100Milliseconds"] as? NSNumber)?.intValue ?? 0,
            longGapRatioOver16Milliseconds: (shimDictionary["longGapRatioOver16Milliseconds"] as? NSNumber)?.doubleValue ?? 0.0,
            longGapRatioOver33Milliseconds: (shimDictionary["longGapRatioOver33Milliseconds"] as? NSNumber)?.doubleValue ?? 0.0,
            longGapRatioOver100Milliseconds: (shimDictionary["longGapRatioOver100Milliseconds"] as? NSNumber)?.doubleValue ?? 0.0,
            intervalHistogram: intervalHistogram.mapValues(\.intValue),
            cadenceClassification: cadenceClassification,
            frameStatusHistogram: frameStatusHistogram.mapValues(\.intValue),
            notes: notes
        )
    }

    public func appendingNotes(_ additionalNotes: [String]) -> Self {
        guard !additionalNotes.isEmpty else {
            return self
        }

        return Self(
            displayID: displayID,
            status: status,
            stopStatus: stopStatus,
            sampleDuration: sampleDuration,
            callbackCount: callbackCount,
            completeFrameCount: completeFrameCount,
            observedFrameRate: observedFrameRate,
            requested120LikeProperties: requested120LikeProperties,
            requestedMinimumFrameTime: requestedMinimumFrameTime,
            requestedQueueDepth: requestedQueueDepth,
            requestedShowCursor: requestedShowCursor,
            appliedPropertyCount: appliedPropertyCount,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            pixelFormat: pixelFormat,
            intervalCount: intervalCount,
            minIntervalMilliseconds: minIntervalMilliseconds,
            maxIntervalMilliseconds: maxIntervalMilliseconds,
            stallCountOver16Milliseconds: stallCountOver16Milliseconds,
            stallCountOver33Milliseconds: stallCountOver33Milliseconds,
            stallCountOver100Milliseconds: stallCountOver100Milliseconds,
            longGapRatioOver16Milliseconds: longGapRatioOver16Milliseconds,
            longGapRatioOver33Milliseconds: longGapRatioOver33Milliseconds,
            longGapRatioOver100Milliseconds: longGapRatioOver100Milliseconds,
            intervalHistogram: intervalHistogram,
            cadenceClassification: cadenceClassification,
            frameStatusHistogram: frameStatusHistogram,
            notes: notes + additionalNotes
        )
    }
}

public enum MDKSkyLightDisplayStreamBenchmark {
    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        configuration: MDKSkyLightDisplayStreamConfiguration
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        try run(
            displayID: displayID,
            sampleDuration: sampleDuration,
            minimumFrameTime: configuration.resolvedMinimumFrameTime,
            queueDepth: configuration.resolvedQueueDepth,
            showCursor: configuration.tuning.showCursor,
            outputWidth: configuration.resolvedOutputWidth == 0 ? nil : configuration.resolvedOutputWidth,
            outputHeight: configuration.resolvedOutputHeight == 0 ? nil : configuration.resolvedOutputHeight,
            pixelFormat: configuration.resolvedPixelFormatOverride == 0 ? nil : configuration.resolvedPixelFormatOverride
        )
    }

    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        request120LikeProperties: Bool
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoSkyLightDisplayStreamBenchmark(
            UInt(displayID),
            sampleDuration,
            request120LikeProperties,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKSkyLightDisplayStreamBenchmarkResult(shimDictionary: payload as NSDictionary)
    }

    public static func run(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        minimumFrameTime: Double,
        queueDepth: Int,
        showCursor: Bool,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        pixelFormat: UInt32? = nil
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        var nsError: NSError?
        let resolvedOutputWidth = UInt(max(outputWidth ?? 0, 0))
        let resolvedOutputHeight = UInt(max(outputHeight ?? 0, 0))
        guard let payload = MDKShimVideoSkyLightDisplayStreamBenchmarkWithParameters(
            UInt(displayID),
            sampleDuration,
            minimumFrameTime,
            queueDepth,
            showCursor,
            resolvedOutputWidth,
            resolvedOutputHeight,
            pixelFormat ?? 0,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKSkyLightDisplayStreamBenchmarkResult(shimDictionary: payload as NSDictionary)
    }
}
