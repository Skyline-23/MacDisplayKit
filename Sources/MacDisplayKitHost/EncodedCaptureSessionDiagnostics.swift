import Foundation
import MacDisplayCaptureKit

enum MDKHostEncodedCaptureConsumerMode: String, Codable, CaseIterable, Sendable {
    case stream
    case callback
}

struct MDKHostEncodedCaptureSessionReport: Codable, Sendable {
    let displayID: UInt32
    let sampleDuration: TimeInterval
    let consumerMode: MDKHostEncodedCaptureConsumerMode
    let codec: MDKVideoEncoderCodec
    let preprocessStrategy: MDKVideoPreprocessStrategy
    let queueProfile: MDKSkyLightDisplayStreamQueueProfile?
    let queueDepth: Int
    let capturePixelFormat: UInt32
    let targetFrameRate: Int
    let hdrMode: String?
    let observedOutputFrameRate: Double
    let consumedFrameCount: UInt64
    let keyFrameCount: UInt64
    let hdrSignaledFrameCount: UInt64
    let streamErrorDescription: String?
    let statistics: MDKEncodedCaptureSessionStatistics
    let firstFrameHDRSignaled: Bool?
    let firstFrameFormatDescriptionSummary: [String: String]
    let averageOutputCallbackLatencyMilliseconds: Double?
    let minimumOutputCallbackLatencyMilliseconds: Double?
    let maximumOutputCallbackLatencyMilliseconds: Double?
    let notes: [String]
}

actor MDKHostEncodedCaptureSessionObserver {
    private var consumedFrameCount: UInt64 = 0
    private var keyFrameCount: UInt64 = 0
    private var hdrSignaledFrameCount: UInt64 = 0
    private var firstFrameHDRSignaled: Bool?
    private var firstFrameFormatDescriptionSummary: [String: String] = [:]
    private var totalOutputCallbackLatencyMilliseconds: Double = 0
    private var outputCallbackLatencySampleCount: UInt64 = 0
    private var minimumOutputCallbackLatencyMilliseconds: Double?
    private var maximumOutputCallbackLatencyMilliseconds: Double?
    private var streamErrorDescription: String?

    func consume(
        stream: AsyncThrowingStream<MDKEncodedFrame, Error>
    ) async {
        do {
            for try await frame in stream {
                record(frame: frame)
            }
        } catch {
            streamErrorDescription = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func consume(frame: MDKEncodedFrame) {
        record(frame: frame)
    }

    func consume(event: MDKEncodedCaptureSessionEvent) {
        if event.kind == .failed, let message = event.message {
            streamErrorDescription = message
        }
    }

    private func record(frame: MDKEncodedFrame) {
        consumedFrameCount += 1
        if frame.isKeyFrame {
            keyFrameCount += 1
        }
        if frame.isHDRSignaled {
            hdrSignaledFrameCount += 1
        }
        if firstFrameHDRSignaled == nil {
            firstFrameHDRSignaled = frame.isHDRSignaled
            firstFrameFormatDescriptionSummary = summarize(formatDescriptionExtensions: frame.formatDescriptionExtensions)
        }
        if let latency = frame.outputCallbackLatencyMilliseconds {
            totalOutputCallbackLatencyMilliseconds += latency
            outputCallbackLatencySampleCount += 1
            minimumOutputCallbackLatencyMilliseconds = min(minimumOutputCallbackLatencyMilliseconds ?? latency, latency)
            maximumOutputCallbackLatencyMilliseconds = max(maximumOutputCallbackLatencyMilliseconds ?? latency, latency)
        }
    }

    func makeReport(
        configuration: MDKEncodedCaptureConfiguration,
        consumerMode: MDKHostEncodedCaptureConsumerMode,
        sampleDuration: TimeInterval,
        statistics: MDKEncodedCaptureSessionStatistics,
        notes: [String]
    ) -> MDKHostEncodedCaptureSessionReport {
        MDKHostEncodedCaptureSessionReport(
            displayID: configuration.displayID,
            sampleDuration: sampleDuration,
            consumerMode: consumerMode,
            codec: configuration.codec,
            preprocessStrategy: configuration.preprocessStrategy,
            queueProfile: configuration.streamConfiguration.queueProfile,
            queueDepth: configuration.streamConfiguration.resolvedQueueDepth,
            capturePixelFormat: configuration.capturePixelFormat
                ?? configuration.streamConfiguration.pixelFormat
                ?? configuration.codec.preferredCapturePixelFormat,
            targetFrameRate: configuration.targetFrameRate,
            hdrMode: configuration.hdrConfiguration.map(Self.describe(hdrConfiguration:)),
            observedOutputFrameRate: sampleDuration > 0
                ? Double(consumedFrameCount) / sampleDuration
                : 0,
            consumedFrameCount: consumedFrameCount,
            keyFrameCount: keyFrameCount,
            hdrSignaledFrameCount: hdrSignaledFrameCount,
            streamErrorDescription: streamErrorDescription,
            statistics: statistics,
            firstFrameHDRSignaled: firstFrameHDRSignaled,
            firstFrameFormatDescriptionSummary: firstFrameFormatDescriptionSummary,
            averageOutputCallbackLatencyMilliseconds: outputCallbackLatencySampleCount > 0
                ? totalOutputCallbackLatencyMilliseconds / Double(outputCallbackLatencySampleCount)
                : nil,
            minimumOutputCallbackLatencyMilliseconds: minimumOutputCallbackLatencyMilliseconds,
            maximumOutputCallbackLatencyMilliseconds: maximumOutputCallbackLatencyMilliseconds,
            notes: notes
        )
    }

    private func summarize(formatDescriptionExtensions: [String: Any]) -> [String: String] {
        var summary: [String: String] = [:]
        for (key, value) in formatDescriptionExtensions {
            summary[key] = summarizeFormatDescriptionValue(value)
        }
        return summary
    }

    private func summarizeFormatDescriptionValue(_ value: Any) -> String {
        if let text = value as? String {
            return text
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        let object = value as AnyObject
        let cfType = object as CFTypeRef
        let typeID = CFGetTypeID(cfType)

        if typeID == CFDataGetTypeID() {
            let cfData = unsafeBitCast(object, to: CFData.self)
            return "CFData(\(CFDataGetLength(cfData)) bytes)"
        }

        if typeID == CFDictionaryGetTypeID() {
            let dictionary = unsafeBitCast(object, to: CFDictionary.self)
            return "CFDictionary(\(CFDictionaryGetCount(dictionary)) entries)"
        }

        if typeID == CFArrayGetTypeID() {
            let array = unsafeBitCast(object, to: CFArray.self)
            return "CFArray(\(CFArrayGetCount(array)) entries)"
        }

        return String(describing: value)
    }

    private static func describe(hdrConfiguration: MDKVideoHDRConfiguration) -> String {
        switch hdrConfiguration.transferFunction {
        case .smpteSt2084PQ:
            return "hdr10-pq"
        case .ituR2100HLG:
            return "hlg"
        case .ituR709:
            return "sdr"
        @unknown default:
            return hdrConfiguration.transferFunction.rawValue
        }
    }
}
