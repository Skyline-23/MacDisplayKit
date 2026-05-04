import CoreMedia
import CoreGraphics
import Foundation

public struct MDKEncodedFrameTileMetadata: Codable, Equatable, Sendable {
    public static let singleFrame = MDKEncodedFrameTileMetadata()

    public let frameGroupID: UInt64
    public let tileIndex: UInt32
    public let tileCount: UInt32
    public let encodedLaneIndex: UInt32
    public let encodedLaneCount: UInt32
    public let tileRegion: CGRect?

    public init(
        frameGroupID: UInt64 = 0,
        tileIndex: UInt32 = 0,
        tileCount: UInt32 = 1,
        encodedLaneIndex: UInt32 = 0,
        encodedLaneCount: UInt32 = 1,
        tileRegion: CGRect? = nil
    ) {
        self.frameGroupID = frameGroupID
        self.tileIndex = tileIndex
        self.tileCount = max(1, tileCount)
        self.encodedLaneIndex = encodedLaneIndex
        self.encodedLaneCount = max(1, encodedLaneCount)
        self.tileRegion = tileRegion
    }
}

public struct MDKEncodedFrameHDRValidationReport: Codable, Equatable, Sendable {
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let hasMasteringDisplayColorVolume: Bool
    public let hasContentLightLevelInfo: Bool
    public let isWideGamut: Bool
    public let isPQ: Bool
    public let isHLG: Bool
    public let isHDRSignaled: Bool

    public init(
        colorPrimaries: String?,
        transferFunction: String?,
        yCbCrMatrix: String?,
        hasMasteringDisplayColorVolume: Bool,
        hasContentLightLevelInfo: Bool,
        isWideGamut: Bool,
        isPQ: Bool,
        isHLG: Bool
    ) {
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.hasMasteringDisplayColorVolume = hasMasteringDisplayColorVolume
        self.hasContentLightLevelInfo = hasContentLightLevelInfo
        self.isWideGamut = isWideGamut
        self.isPQ = isPQ
        self.isHLG = isHLG
        self.isHDRSignaled = (isWideGamut && (isPQ || isHLG)) || hasMasteringDisplayColorVolume || hasContentLightLevelInfo
    }
}

public enum MDKEncodedFrameError: Error, LocalizedError {
    case dataUnavailable

    public var errorDescription: String? {
        switch self {
        case .dataUnavailable:
            return "The encoded sample buffer does not expose a contiguous CMBlockBuffer payload."
        }
    }
}

public final class MDKEncodedFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let codec: MDKVideoEncoderCodec
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let tileMetadata: MDKEncodedFrameTileMetadata
    private let isHDRSignaledOverride: Bool?

    public init(
        sampleBuffer: CMSampleBuffer,
        codec: MDKVideoEncoderCodec,
        sourceSequenceNumber: UInt64,
        sourceDisplayTime: UInt64,
        outputCallbackLatencyMilliseconds: Double?,
        tileMetadata: MDKEncodedFrameTileMetadata = .singleFrame,
        isHDRSignaledOverride: Bool? = nil
    ) {
        self.sampleBuffer = sampleBuffer
        self.codec = codec
        self.sourceSequenceNumber = sourceSequenceNumber
        self.sourceDisplayTime = sourceDisplayTime
        self.outputCallbackLatencyMilliseconds = outputCallbackLatencyMilliseconds
        self.tileMetadata = tileMetadata
        self.isHDRSignaledOverride = isHDRSignaledOverride
    }

    public var presentationTimeStamp: CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    public var duration: CMTime {
        CMSampleBufferGetDuration(sampleBuffer)
    }

    public var isKeyFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
            let firstAttachment = attachments.first else {
            return true
        }
        let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    public var formatDescriptionExtensions: [String: Any] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else {
            return [:]
        }

        var mapped: [String: Any] = [:]
        for (key, value) in extensions {
            mapped[key as String] = value
        }
        return mapped
    }

    public var isHDRSignaled: Bool {
        if let isHDRSignaledOverride {
            return isHDRSignaledOverride
        }
        hdrValidationReport.isHDRSignaled
    }

    public var hdrValidationReport: MDKEncodedFrameHDRValidationReport {
        let extensions = formatDescriptionExtensions
        let colorPrimaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let yCbCrMatrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let isWideGamut = colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ||
            colorPrimaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
        let isPQ = transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        let isHLG = transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let staticMetadataPresence: MDKHEVCHDRStaticMetadataPresence
        if codec == .hevc {
            staticMetadataPresence = MDKHEVCHDRStaticMetadataTransport.presence(in: sampleBuffer)
        } else {
            staticMetadataPresence = MDKHEVCHDRStaticMetadataPresence(
                hasMasteringDisplayColorVolume: extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil,
                hasContentLightLevelInfo: extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil
            )
        }
        return MDKEncodedFrameHDRValidationReport(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            hasMasteringDisplayColorVolume: staticMetadataPresence.hasMasteringDisplayColorVolume,
            hasContentLightLevelInfo: staticMetadataPresence.hasContentLightLevelInfo,
            isWideGamut: isWideGamut,
            isPQ: isPQ,
            isHLG: isHLG
        )
    }

    public func contiguousData() throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw MDKEncodedFrameError.dataUnavailable
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, length > 0 else {
            throw MDKEncodedFrameError.dataUnavailable
        }
        return Data(bytes: dataPointer, count: length)
    }
}
