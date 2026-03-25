import CoreMedia
import Foundation

struct MDKHEVCHDRStaticMetadataPresence: Equatable, Sendable {
    var hasMasteringDisplayColorVolume: Bool
    var hasContentLightLevelInfo: Bool

    var isComplete: Bool {
        hasMasteringDisplayColorVolume && hasContentLightLevelInfo
    }
}

enum MDKHEVCHDRStaticMetadataTransport {
    private static let prefixSEINALUnitType = 39
    private static let suffixSEINALUnitType = 40
    private static let masteringDisplayPayloadType = 137
    private static let contentLightPayloadType = 144
    private static let prefixSEIHeaderBytes: [UInt8] = [0x4E, 0x01]

    static func presence(in sampleBuffer: CMSampleBuffer) -> MDKHEVCHDRStaticMetadataPresence {
        let extensionPresence = extensionPresence(in: sampleBuffer)
        guard !extensionPresence.isComplete,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC,
              let payload = sampleBufferData(sampleBuffer) else {
            return extensionPresence
        }

        let payloadPresence = presence(
            inLengthPrefixedPayload: payload,
            nalUnitHeaderLength: hevcNALUnitHeaderLength(from: formatDescription) ?? 4
        )
        return MDKHEVCHDRStaticMetadataPresence(
            hasMasteringDisplayColorVolume: extensionPresence.hasMasteringDisplayColorVolume || payloadPresence.hasMasteringDisplayColorVolume,
            hasContentLightLevelInfo: extensionPresence.hasContentLightLevelInfo || payloadPresence.hasContentLightLevelInfo
        )
    }

    static func makeAugmentedSampleBufferIfNeeded(
        sampleBuffer: CMSampleBuffer,
        hdrConfiguration: MDKVideoHDRConfiguration,
        isKeyFrame: Bool
    ) -> CMSampleBuffer? {
        guard isKeyFrame,
              hdrConfiguration.transferFunction == .smpteSt2084PQ,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC,
              let payload = sampleBufferData(sampleBuffer) else {
            return nil
        }

        let existingPresence = presence(in: sampleBuffer)
        let needsMasteringDisplay =
            hdrConfiguration.masteringDisplayColorVolume != nil &&
            !existingPresence.hasMasteringDisplayColorVolume
        let needsContentLight =
            hdrConfiguration.contentLightLevelInfo != nil &&
            !existingPresence.hasContentLightLevelInfo
        guard needsMasteringDisplay || needsContentLight else {
            return nil
        }

        let nalUnitHeaderLength = hevcNALUnitHeaderLength(from: formatDescription) ?? 4
        guard let seiNALUnit = makeLengthPrefixedPrefixSEINALUnit(
            nalUnitHeaderLength: nalUnitHeaderLength,
            masteringDisplayColorVolume: needsMasteringDisplay ? hdrConfiguration.masteringDisplayColorVolume : nil,
            contentLightLevelInfo: needsContentLight ? hdrConfiguration.contentLightLevelInfo : nil
        ) else {
            return nil
        }

        var augmentedPayload = Data()
        augmentedPayload.reserveCapacity(seiNALUnit.count + payload.count)
        augmentedPayload.append(seiNALUnit)
        augmentedPayload.append(payload)

        let augmentedFormatDescription =
            makeFormatDescriptionWithStaticMetadata(
                from: formatDescription,
                hdrConfiguration: hdrConfiguration
            ) ?? formatDescription

        return makeSampleBufferCopy(
            from: sampleBuffer,
            data: augmentedPayload,
            formatDescription: augmentedFormatDescription
        )
    }

    static func makeLengthPrefixedPrefixSEINALUnit(
        nalUnitHeaderLength: Int,
        masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume?,
        contentLightLevelInfo: MDKVideoContentLightLevelInfo?
    ) -> Data? {
        guard nalUnitHeaderLength == 1 || nalUnitHeaderLength == 2 || nalUnitHeaderLength == 4 else {
            return nil
        }
        guard masteringDisplayColorVolume != nil || contentLightLevelInfo != nil else {
            return nil
        }

        var rbsp = Data()
        if let masteringDisplayColorVolume {
            appendPayloadHeader(
                payloadType: masteringDisplayPayloadType,
                payloadSize: masteringDisplayColorVolume.encodedData.count,
                to: &rbsp
            )
            rbsp.append(masteringDisplayColorVolume.encodedData)
        }
        if let contentLightLevelInfo {
            appendPayloadHeader(
                payloadType: contentLightPayloadType,
                payloadSize: contentLightLevelInfo.encodedData.count,
                to: &rbsp
            )
            rbsp.append(contentLightLevelInfo.encodedData)
        }
        rbsp.append(0x80)

        var nalUnit = Data(prefixSEIHeaderBytes)
        appendRBSPWithEmulationPrevention(rbsp, to: &nalUnit)

        var lengthPrefix = Data(repeating: 0, count: nalUnitHeaderLength)
        let nalUnitLength = nalUnit.count
        for byteIndex in 0..<nalUnitHeaderLength {
            let shift = (nalUnitHeaderLength - byteIndex - 1) * 8
            lengthPrefix[byteIndex] = UInt8((nalUnitLength >> shift) & 0xFF)
        }

        var output = Data()
        output.reserveCapacity(lengthPrefix.count + nalUnit.count)
        output.append(lengthPrefix)
        output.append(nalUnit)
        return output
    }

    private static func extensionPresence(in sampleBuffer: CMSampleBuffer) -> MDKHEVCHDRStaticMetadataPresence {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else {
            return MDKHEVCHDRStaticMetadataPresence(
                hasMasteringDisplayColorVolume: false,
                hasContentLightLevelInfo: false
            )
        }

        return MDKHEVCHDRStaticMetadataPresence(
            hasMasteringDisplayColorVolume: extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] != nil,
            hasContentLightLevelInfo: extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] != nil
        )
    }

    private static func sampleBufferData(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else {
            return nil
        }

        var data = Data(count: totalLength)
        let status = data.withUnsafeMutableBytes { mutableBytes in
            guard let baseAddress = mutableBytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func hevcNALUnitHeaderLength(from formatDescription: CMFormatDescription) -> Int? {
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard status == noErr, parameterSetCount > 0 else {
            return nil
        }
        return Int(nalUnitHeaderLength)
    }

    private static func makeFormatDescriptionWithStaticMetadata(
        from formatDescription: CMFormatDescription,
        hdrConfiguration: MDKVideoHDRConfiguration
    ) -> CMFormatDescription? {
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr, parameterSetCount >= 3 else {
            return nil
        }

        var parameterSetPointers: [UnsafePointer<UInt8>] = []
        parameterSetPointers.reserveCapacity(parameterSetCount)
        var parameterSetSizes: [Int] = []
        parameterSetSizes.reserveCapacity(parameterSetCount)
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                return nil
            }
            parameterSetPointers.append(pointer)
            parameterSetSizes.append(size)
        }

        let extensions = NSMutableDictionary(
            dictionary: (CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?) ?? [:]
        )
        extensions[kCMFormatDescriptionExtension_ColorPrimaries] = hdrConfiguration.colorPrimaries.vtValue
        extensions[kCMFormatDescriptionExtension_TransferFunction] = hdrConfiguration.transferFunction.vtValue
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = hdrConfiguration.yCbCrMatrix.vtValue
        if let masteringDisplayColorVolume = hdrConfiguration.masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] =
                masteringDisplayColorVolume.encodedData as CFData
        }
        if let contentLightLevelInfo = hdrConfiguration.contentLightLevelInfo {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] =
                contentLightLevelInfo.encodedData as CFData
        }

        var newFormatDescription: CMFormatDescription?
        let createStatus = parameterSetPointers.withUnsafeBufferPointer { pointerBuffer in
            parameterSetSizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointerBuffer.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: nalUnitHeaderLength,
                    extensions: extensions,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }
        guard createStatus == noErr else {
            return nil
        }
        return newFormatDescription
    }

    private static func makeSampleBufferCopy(
        from sampleBuffer: CMSampleBuffer,
        data: Data,
        formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1 else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        let createBlockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlockBufferStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let replaceStatus = data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var sampleTimingEntryCount: Int = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &sampleTimingEntryCount
        )
        guard countStatus == noErr, sampleTimingEntryCount > 0 else {
            return nil
        }

        var sampleTiming = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: sampleTimingEntryCount
        )
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: sampleTiming.count,
            arrayToFill: &sampleTiming,
            entriesNeededOut: &sampleTimingEntryCount
        )
        guard timingStatus == noErr else {
            return nil
        }

        var sampleSize = data.count
        var newSampleBuffer: CMSampleBuffer?
        let createSampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: sampleTiming.count,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &newSampleBuffer
        )
        guard createSampleBufferStatus == noErr else {
            return nil
        }

        return newSampleBuffer
    }

    private static func presence(
        inLengthPrefixedPayload payload: Data,
        nalUnitHeaderLength: Int
    ) -> MDKHEVCHDRStaticMetadataPresence {
        guard nalUnitHeaderLength > 0, payload.count > nalUnitHeaderLength else {
            return MDKHEVCHDRStaticMetadataPresence(
                hasMasteringDisplayColorVolume: false,
                hasContentLightLevelInfo: false
            )
        }

        var presence = MDKHEVCHDRStaticMetadataPresence(
            hasMasteringDisplayColorVolume: false,
            hasContentLightLevelInfo: false
        )

        payload.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + nalUnitHeaderLength <= bytes.count {
                let nalLength = readNALUnitLength(
                    from: bytes,
                    offset: offset,
                    nalUnitHeaderLength: nalUnitHeaderLength
                )
                offset += nalUnitHeaderLength
                guard nalLength > 0, offset + nalLength <= bytes.count else {
                    break
                }

                let nalType = Int((bytes[offset] >> 1) & 0x3F)
                if nalType == prefixSEINALUnitType || nalType == suffixSEINALUnitType {
                    let seiPresence = parseSEIPresence(
                        in: bytes[offset..<(offset + nalLength)]
                    )
                    presence.hasMasteringDisplayColorVolume =
                        presence.hasMasteringDisplayColorVolume || seiPresence.hasMasteringDisplayColorVolume
                    presence.hasContentLightLevelInfo =
                        presence.hasContentLightLevelInfo || seiPresence.hasContentLightLevelInfo
                    if presence.isComplete {
                        break
                    }
                }

                offset += nalLength
            }
        }

        return presence
    }

    private static func parseSEIPresence<Bytes: Collection>(
        in nalUnit: Bytes
    ) -> MDKHEVCHDRStaticMetadataPresence where Bytes.Element == UInt8 {
        guard nalUnit.count > 2 else {
            return MDKHEVCHDRStaticMetadataPresence(
                hasMasteringDisplayColorVolume: false,
                hasContentLightLevelInfo: false
            )
        }

        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(nalUnit.count - 2)
        var consecutiveZeroCount = 0
        for byte in nalUnit.dropFirst(2) {
            if consecutiveZeroCount >= 2 && byte == 0x03 {
                consecutiveZeroCount = 0
                continue
            }
            rbsp.append(byte)
            consecutiveZeroCount = byte == 0 ? consecutiveZeroCount + 1 : 0
        }

        var presence = MDKHEVCHDRStaticMetadataPresence(
            hasMasteringDisplayColorVolume: false,
            hasContentLightLevelInfo: false
        )
        var offset = 0
        while offset < rbsp.count {
            if offset == rbsp.count - 1 && rbsp[offset] == 0x80 {
                break
            }

            var payloadType = 0
            while offset < rbsp.count {
                let value = Int(rbsp[offset])
                offset += 1
                payloadType += value
                if value != 0xFF {
                    break
                }
            }

            var payloadSize = 0
            while offset < rbsp.count {
                let value = Int(rbsp[offset])
                offset += 1
                payloadSize += value
                if value != 0xFF {
                    break
                }
            }

            guard payloadSize >= 0, offset + payloadSize <= rbsp.count else {
                break
            }

            if payloadType == masteringDisplayPayloadType {
                presence.hasMasteringDisplayColorVolume = true
            } else if payloadType == contentLightPayloadType {
                presence.hasContentLightLevelInfo = true
            }
            if presence.isComplete {
                break
            }

            offset += payloadSize
        }
        return presence
    }

    private static func readNALUnitLength(
        from bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        nalUnitHeaderLength: Int
    ) -> Int {
        var length = 0
        for byteIndex in 0..<nalUnitHeaderLength {
            length = (length << 8) | Int(bytes[offset + byteIndex])
        }
        return length
    }

    private static func appendPayloadHeader(
        payloadType: Int,
        payloadSize: Int,
        to data: inout Data
    ) {
        appendExpandedValue(payloadType, to: &data)
        appendExpandedValue(payloadSize, to: &data)
    }

    private static func appendExpandedValue(
        _ value: Int,
        to data: inout Data
    ) {
        var remaining = value
        while remaining >= 0xFF {
            data.append(0xFF)
            remaining -= 0xFF
        }
        data.append(UInt8(remaining))
    }

    private static func appendRBSPWithEmulationPrevention(
        _ rbsp: Data,
        to data: inout Data
    ) {
        var consecutiveZeroCount = 0
        for byte in rbsp {
            if consecutiveZeroCount >= 2 && byte <= 0x03 {
                data.append(0x03)
                consecutiveZeroCount = 0
            }
            data.append(byte)
            consecutiveZeroCount = byte == 0 ? consecutiveZeroCount + 1 : 0
        }
    }
}
