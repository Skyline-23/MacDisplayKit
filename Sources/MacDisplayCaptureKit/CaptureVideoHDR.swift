import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct MDKVideoChromaticityPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum MDKVideoHDRMetadataInsertionMode: String, Codable, Equatable, Sendable {
    case automatic
    case disabled

    var vtValue: CFString {
        switch self {
        case .automatic:
            return kVTHDRMetadataInsertionMode_Auto
        case .disabled:
            return kVTHDRMetadataInsertionMode_None
        }
    }
}

public enum MDKVideoColorPrimaries: String, Codable, Equatable, Sendable {
    case ituR709
    case ituR2020
    case p3D65

    var vtValue: CFString {
        switch self {
        case .ituR709:
            return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case .ituR2020:
            return kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case .p3D65:
            return kCMFormatDescriptionColorPrimaries_P3_D65
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709:
            return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .ituR2020:
            return kCVImageBufferColorPrimaries_ITU_R_2020
        case .p3D65:
            return kCVImageBufferColorPrimaries_P3_D65
        }
    }
}

public enum MDKVideoTransferFunction: String, Codable, Equatable, Sendable {
    case ituR709
    case smpteSt2084PQ
    case ituR2100HLG

    var vtValue: CFString {
        switch self {
        case .ituR709:
            return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ:
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG:
            return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709:
            return kCVImageBufferTransferFunction_ITU_R_709_2
        case .smpteSt2084PQ:
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .ituR2100HLG:
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }
}

public enum MDKVideoYCbCrMatrix: String, Codable, Equatable, Sendable {
    case ituR709
    case ituR2020

    var vtValue: CFString {
        switch self {
        case .ituR709:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .ituR2020:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
    }

    var imageBufferValue: CFString {
        switch self {
        case .ituR709:
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .ituR2020:
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
    }
}

public struct MDKVideoMasteringDisplayColorVolume: Codable, Equatable, Sendable {
    public let redPrimary: MDKVideoChromaticityPoint
    public let greenPrimary: MDKVideoChromaticityPoint
    public let bluePrimary: MDKVideoChromaticityPoint
    public let whitePoint: MDKVideoChromaticityPoint
    public let maxLuminance: Double
    public let minLuminance: Double

    public init(
        redPrimary: MDKVideoChromaticityPoint,
        greenPrimary: MDKVideoChromaticityPoint,
        bluePrimary: MDKVideoChromaticityPoint,
        whitePoint: MDKVideoChromaticityPoint,
        maxLuminance: Double,
        minLuminance: Double
    ) {
        self.redPrimary = redPrimary
        self.greenPrimary = greenPrimary
        self.bluePrimary = bluePrimary
        self.whitePoint = whitePoint
        self.maxLuminance = maxLuminance
        self.minLuminance = minLuminance
    }

    public static func hdr10Default(
        peakLuminance: Double = 1_000,
        minimumLuminance: Double = 0.05
    ) -> Self {
        Self(
            redPrimary: MDKVideoChromaticityPoint(x: 0.708, y: 0.292),
            greenPrimary: MDKVideoChromaticityPoint(x: 0.170, y: 0.797),
            bluePrimary: MDKVideoChromaticityPoint(x: 0.131, y: 0.046),
            whitePoint: MDKVideoChromaticityPoint(x: 0.3127, y: 0.3290),
            maxLuminance: peakLuminance,
            minLuminance: minimumLuminance
        )
    }
}

public struct MDKVideoContentLightLevelInfo: Codable, Equatable, Sendable {
    public let maximumContentLightLevel: UInt16
    public let maximumFrameAverageLightLevel: UInt16

    public init(
        maximumContentLightLevel: UInt16,
        maximumFrameAverageLightLevel: UInt16
    ) {
        self.maximumContentLightLevel = maximumContentLightLevel
        self.maximumFrameAverageLightLevel = maximumFrameAverageLightLevel
    }

    public static func hdr10Default(
        maximumContentLightLevel: UInt16 = 1_000,
        maximumFrameAverageLightLevel: UInt16 = 400
    ) -> Self {
        Self(
            maximumContentLightLevel: maximumContentLightLevel,
            maximumFrameAverageLightLevel: maximumFrameAverageLightLevel
        )
    }
}

public struct MDKVideoHDRConfiguration: Codable, Equatable, Sendable {
    public let sourceColorPrimaries: MDKVideoColorPrimaries?
    public let colorPrimaries: MDKVideoColorPrimaries
    public let transferFunction: MDKVideoTransferFunction
    public let yCbCrMatrix: MDKVideoYCbCrMatrix
    public let metadataInsertionMode: MDKVideoHDRMetadataInsertionMode
    public let masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume?
    public let contentLightLevelInfo: MDKVideoContentLightLevelInfo?

    public init(
        sourceColorPrimaries: MDKVideoColorPrimaries? = nil,
        colorPrimaries: MDKVideoColorPrimaries,
        transferFunction: MDKVideoTransferFunction,
        yCbCrMatrix: MDKVideoYCbCrMatrix,
        metadataInsertionMode: MDKVideoHDRMetadataInsertionMode = .automatic,
        masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume? = nil,
        contentLightLevelInfo: MDKVideoContentLightLevelInfo? = nil
    ) {
        self.sourceColorPrimaries = sourceColorPrimaries
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.metadataInsertionMode = metadataInsertionMode
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    public static func hdr10(
        sourceColorPrimaries: MDKVideoColorPrimaries? = nil,
        masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume = .hdr10Default(),
        contentLightLevelInfo: MDKVideoContentLightLevelInfo = .hdr10Default()
    ) -> Self {
        Self(
            sourceColorPrimaries: sourceColorPrimaries,
            colorPrimaries: .ituR2020,
            transferFunction: .smpteSt2084PQ,
            yCbCrMatrix: .ituR2020,
            metadataInsertionMode: .automatic,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    public static func hlg(
        sourceColorPrimaries: MDKVideoColorPrimaries? = nil,
        contentLightLevelInfo: MDKVideoContentLightLevelInfo? = nil
    ) -> Self {
        Self(
            sourceColorPrimaries: sourceColorPrimaries,
            colorPrimaries: .ituR2020,
            transferFunction: .ituR2100HLG,
            yCbCrMatrix: .ituR2020,
            metadataInsertionMode: .automatic,
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }
}

extension MDKVideoHDRConfiguration {
    func negotiatedForEncodedDelivery(codec: MDKVideoEncoderCodec) -> Self {
        guard transferFunction != .ituR709 else {
            return self
        }
        let candidates = encodedDeliveryCandidates(for: codec)
        let supportedCandidates = candidates.filter { $0.isSupportedEncodedDeliveryProfile(for: codec) }
        return supportedCandidates.min {
            encodedDeliveryCompatibilityScore(to: $0) < encodedDeliveryCompatibilityScore(to: $1)
        } ?? self
    }

    private func encodedDeliveryCandidates(for codec: MDKVideoEncoderCodec) -> [Self] {
        switch codec {
        case .hevc:
            var candidates = [self]
            let wideGamutP3Candidate = Self(
                sourceColorPrimaries: sourceColorPrimaries,
                colorPrimaries: .p3D65,
                transferFunction: encodedDeliveryTransferFallback,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: metadataInsertionMode,
                masteringDisplayColorVolume: masteringDisplayColorVolume,
                contentLightLevelInfo: contentLightLevelInfo
            )
            if wideGamutP3Candidate != self {
                candidates.append(wideGamutP3Candidate)
            }
            let bt2020Candidate = Self(
                sourceColorPrimaries: sourceColorPrimaries,
                colorPrimaries: .ituR2020,
                transferFunction: encodedDeliveryTransferFallback,
                yCbCrMatrix: .ituR2020,
                metadataInsertionMode: metadataInsertionMode,
                masteringDisplayColorVolume: masteringDisplayColorVolume,
                contentLightLevelInfo: contentLightLevelInfo
            )
            if bt2020Candidate != self {
                candidates.append(bt2020Candidate)
            }
            return candidates
        case .h264, .proResProxy:
            return [self]
        }
    }

    private func isSupportedEncodedDeliveryProfile(for codec: MDKVideoEncoderCodec) -> Bool {
        switch codec {
        case .hevc:
            let hdrTransferSupported = transferFunction == .smpteSt2084PQ || transferFunction == .ituR2100HLG
            guard hdrTransferSupported else {
                return false
            }
            switch colorPrimaries {
            case .ituR2020:
                return yCbCrMatrix == .ituR2020
            case .p3D65, .ituR709:
                return yCbCrMatrix == .ituR709
            }
        case .h264, .proResProxy:
            return true
        }
    }

    private var encodedDeliveryTransferFallback: MDKVideoTransferFunction {
        switch transferFunction {
        case .ituR2100HLG:
            return .ituR2100HLG
        case .ituR709, .smpteSt2084PQ:
            return .smpteSt2084PQ
        }
    }

    private func encodedDeliveryCompatibilityScore(to candidate: Self) -> Int {
        var score = 0
        if colorPrimaries != candidate.colorPrimaries {
            score += 8
        }
        if yCbCrMatrix != candidate.yCbCrMatrix {
            score += 8
        }
        if transferFunction != candidate.transferFunction {
            score += 4
        }
        if metadataInsertionMode != candidate.metadataInsertionMode {
            score += 2
        }
        if (masteringDisplayColorVolume != nil) != (candidate.masteringDisplayColorVolume != nil) {
            score += 1
        }
        if (contentLightLevelInfo != nil) != (candidate.contentLightLevelInfo != nil) {
            score += 1
        }
        return score
    }

    var sessionProperties: [(CFString, CFTypeRef, String)] {
        var properties: [(CFString, CFTypeRef, String)] = [
            (kVTCompressionPropertyKey_ColorPrimaries, colorPrimaries.vtValue, "ColorPrimaries"),
            (kVTCompressionPropertyKey_TransferFunction, transferFunction.vtValue, "TransferFunction"),
            (kVTCompressionPropertyKey_YCbCrMatrix, yCbCrMatrix.vtValue, "YCbCrMatrix")
        ]

        if transferFunction != .ituR709 {
            properties.append(
                (
                    kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                    metadataInsertionMode.vtValue,
                    "HDRMetadataInsertionMode"
                )
            )
        }

        if let masteringDisplayColorVolume {
            properties.append(
                (
                    kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                    masteringDisplayColorVolume.encodedData as CFData,
                    "MasteringDisplayColorVolume"
                )
            )
        }
        if let contentLightLevelInfo {
            properties.append(
                (
                    kVTCompressionPropertyKey_ContentLightLevelInfo,
                    contentLightLevelInfo.encodedData as CFData,
                    "ContentLightLevelInfo"
                )
            )
        }

        return properties
    }

    func apply(to imageBuffer: CVImageBuffer) {
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            colorPrimaries.imageBufferValue,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            transferFunction.imageBufferValue,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            yCbCrMatrix.imageBufferValue,
            .shouldPropagate
        )
        if let masteringDisplayColorVolume {
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                masteringDisplayColorVolume.encodedData as CFData,
                .shouldPropagate
            )
        }
        if let contentLightLevelInfo {
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                contentLightLevelInfo.encodedData as CFData,
                .shouldPropagate
            )
        }
    }
}

extension MDKVideoMasteringDisplayColorVolume {
    var encodedData: Data {
        var data = Data(capacity: 24)
        [
            redPrimary.x,
            redPrimary.y,
            greenPrimary.x,
            greenPrimary.y,
            bluePrimary.x,
            bluePrimary.y,
            whitePoint.x,
            whitePoint.y
        ]
        .map(Self.encodeChromaticity)
        .forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        [Self.encodeLuminance(maxLuminance), Self.encodeLuminance(minLuminance)].forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func encodeChromaticity(_ value: Double) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        return UInt16(min(max((clamped * 50_000).rounded(), 0), Double(UInt16.max)))
    }

    private static func encodeLuminance(_ value: Double) -> UInt32 {
        let clamped = max(value, 0)
        return UInt32(min((clamped * 10_000).rounded(), Double(UInt32.max)))
    }
}

extension MDKVideoContentLightLevelInfo {
    var encodedData: Data {
        var data = Data(capacity: 4)
        [maximumContentLightLevel, maximumFrameAverageLightLevel].forEach { value in
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
