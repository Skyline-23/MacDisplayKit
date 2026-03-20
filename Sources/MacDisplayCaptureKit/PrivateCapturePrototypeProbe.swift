import Foundation
import MacDisplayKitObjCShim

public struct MDKPrivateCaptureProbeResult: Codable, Equatable, Sendable {
    public let entryPoint: MDKPrivateCaptureEntryPoint
    public let displayID: UInt32
    public let surfaceWidth: Int
    public let surfaceHeight: Int
    public let bytesPerRow: Int
    public let pixelFormat: UInt32
    public let sampleWord: UInt32
    public let captureValue: UInt32?
    public let status: Int32
    public let surfacePopulated: Bool
    public let requestedExtendedRange: Bool
    public let extendedRangeApplied: Bool
    public let proxiedFrameAvailable: Bool?
    public let notes: [String]

    public init(
        entryPoint: MDKPrivateCaptureEntryPoint,
        displayID: UInt32,
        surfaceWidth: Int,
        surfaceHeight: Int,
        bytesPerRow: Int,
        pixelFormat: UInt32,
        sampleWord: UInt32,
        captureValue: UInt32?,
        status: Int32,
        surfacePopulated: Bool,
        requestedExtendedRange: Bool,
        extendedRangeApplied: Bool,
        proxiedFrameAvailable: Bool?,
        notes: [String]
    ) {
        self.entryPoint = entryPoint
        self.displayID = displayID
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.sampleWord = sampleWord
        self.captureValue = captureValue
        self.status = status
        self.surfacePopulated = surfacePopulated
        self.requestedExtendedRange = requestedExtendedRange
        self.extendedRangeApplied = extendedRangeApplied
        self.proxiedFrameAvailable = proxiedFrameAvailable
        self.notes = notes
    }

    init(shimDictionary: NSDictionary) throws {
        guard
            let entryPointRaw = shimDictionary["entryPoint"] as? String,
            let entryPoint = MDKPrivateCaptureEntryPoint(rawValue: entryPointRaw),
            let displayIDNumber = shimDictionary["displayID"] as? NSNumber,
            let surfaceWidthNumber = shimDictionary["surfaceWidth"] as? NSNumber,
            let surfaceHeightNumber = shimDictionary["surfaceHeight"] as? NSNumber,
            let bytesPerRowNumber = shimDictionary["bytesPerRow"] as? NSNumber,
            let pixelFormatNumber = shimDictionary["pixelFormat"] as? NSNumber,
            let sampleWordNumber = shimDictionary["sampleWord"] as? NSNumber,
            let statusNumber = shimDictionary["status"] as? NSNumber,
            let surfacePopulatedNumber = shimDictionary["surfacePopulated"] as? NSNumber,
            let requestedExtendedRangeNumber = shimDictionary["requestedExtendedRange"] as? NSNumber,
            let extendedRangeAppliedNumber = shimDictionary["extendedRangeApplied"] as? NSNumber,
            let notes = shimDictionary["notes"] as? [String]
        else {
            throw MDKPrivateCapturePrototypeProbeError.invalidShimPayload
        }

        self.init(
            entryPoint: entryPoint,
            displayID: displayIDNumber.uint32Value,
            surfaceWidth: surfaceWidthNumber.intValue,
            surfaceHeight: surfaceHeightNumber.intValue,
            bytesPerRow: bytesPerRowNumber.intValue,
            pixelFormat: pixelFormatNumber.uint32Value,
            sampleWord: sampleWordNumber.uint32Value,
            captureValue: (shimDictionary["captureValue"] as? NSNumber)?.uint32Value,
            status: statusNumber.int32Value,
            surfacePopulated: surfacePopulatedNumber.boolValue,
            requestedExtendedRange: requestedExtendedRangeNumber.boolValue,
            extendedRangeApplied: extendedRangeAppliedNumber.boolValue,
            proxiedFrameAvailable: (shimDictionary["proxiedFrameAvailable"] as? NSNumber)?.boolValue,
            notes: notes
        )
    }
}

public enum MDKPrivateCapturePrototypeProbeError: Error, Equatable, Sendable {
    case unavailable
    case invalidShimPayload
}

public enum MDKPrivateCapturePrototypeProbe {
    public static func captureSingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoPrivateCaptureSingleFrame(
            UInt(displayID),
            requestExtendedRange,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKPrivateCaptureProbeResult(shimDictionary: payload as NSDictionary)
    }

    public static func captureProxySingleFrame(
        displayID: UInt32,
        requestExtendedRange: Bool
    ) throws -> MDKPrivateCaptureProbeResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoPrivateProxyCaptureSingleFrame(
            UInt(displayID),
            requestExtendedRange,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKPrivateCaptureProbeResult(shimDictionary: payload as NSDictionary)
    }
}
