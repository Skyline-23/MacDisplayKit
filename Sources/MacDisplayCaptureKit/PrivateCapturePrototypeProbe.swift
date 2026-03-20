import Foundation
import MacDisplayKitObjCShim

public enum MDKPrivateDisplayStreamPropertiesProfile: String, Codable, Equatable, Sendable, CaseIterable {
    case minimal
    case rectlessMinimal
    case timedMinimal
    case none
    case fullPublic

    var shimValue: Int {
        switch self {
        case .minimal:
            return 0
        case .rectlessMinimal:
            return 1
        case .timedMinimal:
            return 2
        case .none:
            return 3
        case .fullPublic:
            return 4
        }
    }
}

public enum MDKPrivateDisplayStreamPortMode: String, Codable, Equatable, Sendable, CaseIterable {
    case receiveSend
    case receiveOnly

    var shimValue: Int {
        switch self {
        case .receiveSend:
            return 0
        case .receiveOnly:
            return 1
        }
    }
}

public enum MDKPrivateDisplayStreamSelectiveSharingMode: String, Codable, Equatable, Sendable, CaseIterable {
    case zero
    case displayID
    case fixedNonZero

    var shimValue: Int {
        switch self {
        case .zero:
            return 0
        case .displayID:
            return 1
        case .fixedNonZero:
            return 2
        }
    }
}

public struct MDKPrivateDisplayStreamProbeConfiguration: Codable, Equatable, Sendable {
    public let streamPropertiesProfile: MDKPrivateDisplayStreamPropertiesProfile
    public let portMode: MDKPrivateDisplayStreamPortMode
    public let selectiveSharingMode: MDKPrivateDisplayStreamSelectiveSharingMode

    public init(
        streamPropertiesProfile: MDKPrivateDisplayStreamPropertiesProfile,
        portMode: MDKPrivateDisplayStreamPortMode,
        selectiveSharingMode: MDKPrivateDisplayStreamSelectiveSharingMode
    ) {
        self.streamPropertiesProfile = streamPropertiesProfile
        self.portMode = portMode
        self.selectiveSharingMode = selectiveSharingMode
    }

    public static let defaultConfiguration = Self(
        streamPropertiesProfile: .minimal,
        portMode: .receiveSend,
        selectiveSharingMode: .zero
    )

    public static let recommendedMatrix: [Self] = [
        .init(streamPropertiesProfile: .minimal, portMode: .receiveSend, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .rectlessMinimal, portMode: .receiveSend, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .timedMinimal, portMode: .receiveSend, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .none, portMode: .receiveSend, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .fullPublic, portMode: .receiveSend, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .minimal, portMode: .receiveOnly, selectiveSharingMode: .zero),
        .init(streamPropertiesProfile: .minimal, portMode: .receiveSend, selectiveSharingMode: .displayID),
    ]
}

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
    public let portStatus: Int32?
    public let portTypeStatus: Int32?
    public let portType: UInt32?
    public let portMessageCount: UInt32?
    public let portQueueLimit: UInt32?
    public let portSequenceNumber: UInt32?
    public let portMessagesWaiting: Bool?
    public let streamPropertiesProfile: String?
    public let portMode: String?
    public let selectiveSharingMode: String?
    public let selectiveSharingHigh: UInt64?
    public let selectiveSharingLow: UInt64?
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
        portStatus: Int32?,
        portTypeStatus: Int32?,
        portType: UInt32?,
        portMessageCount: UInt32?,
        portQueueLimit: UInt32?,
        portSequenceNumber: UInt32?,
        portMessagesWaiting: Bool?,
        streamPropertiesProfile: String?,
        portMode: String?,
        selectiveSharingMode: String?,
        selectiveSharingHigh: UInt64?,
        selectiveSharingLow: UInt64?,
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
        self.portStatus = portStatus
        self.portTypeStatus = portTypeStatus
        self.portType = portType
        self.portMessageCount = portMessageCount
        self.portQueueLimit = portQueueLimit
        self.portSequenceNumber = portSequenceNumber
        self.portMessagesWaiting = portMessagesWaiting
        self.streamPropertiesProfile = streamPropertiesProfile
        self.portMode = portMode
        self.selectiveSharingMode = selectiveSharingMode
        self.selectiveSharingHigh = selectiveSharingHigh
        self.selectiveSharingLow = selectiveSharingLow
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
            portStatus: (shimDictionary["portStatus"] as? NSNumber)?.int32Value,
            portTypeStatus: (shimDictionary["portTypeStatus"] as? NSNumber)?.int32Value,
            portType: (shimDictionary["portType"] as? NSNumber)?.uint32Value,
            portMessageCount: (shimDictionary["portMessageCount"] as? NSNumber)?.uint32Value,
            portQueueLimit: (shimDictionary["portQueueLimit"] as? NSNumber)?.uint32Value,
            portSequenceNumber: (shimDictionary["portSequenceNumber"] as? NSNumber)?.uint32Value,
            portMessagesWaiting: (shimDictionary["portMessagesWaiting"] as? NSNumber)?.boolValue,
            streamPropertiesProfile: shimDictionary["streamPropertiesProfile"] as? String,
            portMode: shimDictionary["portMode"] as? String,
            selectiveSharingMode: shimDictionary["selectiveSharingMode"] as? String,
            selectiveSharingHigh: (shimDictionary["selectiveSharingHigh"] as? NSNumber)?.uint64Value,
            selectiveSharingLow: (shimDictionary["selectiveSharingLow"] as? NSNumber)?.uint64Value,
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

    public static func createDisplayStream(
        displayID: UInt32
    ) throws -> MDKPrivateCaptureProbeResult {
        try createDisplayStream(
            displayID: displayID,
            configuration: .defaultConfiguration
        )
    }

    public static func createDisplayStream(
        displayID: UInt32,
        configuration: MDKPrivateDisplayStreamProbeConfiguration
    ) throws -> MDKPrivateCaptureProbeResult {
        var nsError: NSError?
        guard let payload = MDKShimVideoPrivateDisplayStreamProbeWithParameters(
            UInt(displayID),
            configuration.streamPropertiesProfile.shimValue,
            configuration.portMode.shimValue,
            configuration.selectiveSharingMode.shimValue,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKPrivateCapturePrototypeProbeError.unavailable
        }

        return try MDKPrivateCaptureProbeResult(shimDictionary: payload as NSDictionary)
    }

    public static func createDisplayStreamMatrix(
        displayID: UInt32,
        configurations: [MDKPrivateDisplayStreamProbeConfiguration] = MDKPrivateDisplayStreamProbeConfiguration.recommendedMatrix
    ) throws -> [MDKPrivateCaptureProbeResult] {
        try configurations.map { configuration in
            try createDisplayStream(displayID: displayID, configuration: configuration)
        }
    }
}
