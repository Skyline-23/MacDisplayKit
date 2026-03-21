import Foundation
import MacDisplayKitObjCShim

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
            intervalHistogram: intervalHistogram.mapValues(\.intValue),
            cadenceClassification: cadenceClassification,
            frameStatusHistogram: frameStatusHistogram.mapValues(\.intValue),
            notes: notes
        )
    }
}

public enum MDKSkyLightDisplayStreamBenchmark {
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
        showCursor: Bool
    ) throws -> MDKSkyLightDisplayStreamBenchmarkResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoSkyLightDisplayStreamBenchmarkWithParameters(
            UInt(displayID),
            sampleDuration,
            minimumFrameTime,
            queueDepth,
            showCursor,
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
