import Foundation
import MacDisplayKitObjCShim

public struct MDKPrivateCaptureBenchmarkResult: Codable, Equatable, Sendable {
    public let probe: MDKPrivateCaptureProbeResult
    public let sampleDuration: TimeInterval
    public let iterationCount: UInt64
    public let populatedFrameCount: UInt64
    public let observedFrameRate: Double
    public let populatedFrameRate: Double

    public init(
        probe: MDKPrivateCaptureProbeResult,
        sampleDuration: TimeInterval,
        iterationCount: UInt64,
        populatedFrameCount: UInt64,
        observedFrameRate: Double,
        populatedFrameRate: Double
    ) {
        self.probe = probe
        self.sampleDuration = sampleDuration
        self.iterationCount = iterationCount
        self.populatedFrameCount = populatedFrameCount
        self.observedFrameRate = observedFrameRate
        self.populatedFrameRate = populatedFrameRate
    }

    init(shimDictionary: NSDictionary) throws {
        guard
            let sampleDurationNumber = shimDictionary["sampleDuration"] as? NSNumber,
            let iterationCountNumber = shimDictionary["iterationCount"] as? NSNumber,
            let populatedFrameCountNumber = shimDictionary["populatedFrameCount"] as? NSNumber,
            let observedFrameRateNumber = shimDictionary["observedFrameRate"] as? NSNumber,
            let populatedFrameRateNumber = shimDictionary["populatedFrameRate"] as? NSNumber
        else {
            throw MDKPrivateCapturePrototypeProbeError.invalidShimPayload
        }

        self.init(
            probe: try MDKPrivateCaptureProbeResult(shimDictionary: shimDictionary),
            sampleDuration: sampleDurationNumber.doubleValue,
            iterationCount: iterationCountNumber.uint64Value,
            populatedFrameCount: populatedFrameCountNumber.uint64Value,
            observedFrameRate: observedFrameRateNumber.doubleValue,
            populatedFrameRate: populatedFrameRateNumber.doubleValue
        )
    }
}

public enum MDKPrivateCapturePrototypeBenchmark {
    public static func run(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoPrivateCaptureBenchmark(
            UInt(displayID),
            requestExtendedRange,
            sampleDuration,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKPrivateCaptureBenchmarkResult(shimDictionary: payload as NSDictionary)
    }

    public static func runProxy(
        displayID: UInt32,
        requestExtendedRange: Bool,
        sampleDuration: TimeInterval
    ) throws -> MDKPrivateCaptureBenchmarkResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoPrivateProxyCaptureBenchmark(
            UInt(displayID),
            requestExtendedRange,
            sampleDuration,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKPrivateCaptureBenchmarkResult(shimDictionary: payload as NSDictionary)
    }
}
