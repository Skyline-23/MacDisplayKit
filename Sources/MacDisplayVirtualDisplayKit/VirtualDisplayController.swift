import Foundation
import MacDisplayKitObjCShim

@objc
public enum MDKDisplayGamut: Int {
    case unknown = 0
    case sRGB = 1
    case displayP3 = 2
    case rec2020 = 3
}

@objc
public enum MDKDisplayTransfer: Int {
    case unknown = 0
    case sdr = 1
    case pq = 2
    case hlg = 3
}

@objcMembers
public final class MDKVirtualDisplayController: NSObject {
    public static func createDisplay(
        specification: MDKVirtualDisplaySpecification,
        displayGamut: MDKDisplayGamut = .unknown,
        displayTransfer: MDKDisplayTransfer = .unknown
    ) -> String? {
        MDKShimCreateVirtualDisplay(
            specification.clientIdentifier,
            specification.clientName,
            numericCast(specification.logicalWidth),
            numericCast(specification.logicalHeight),
            numericCast(specification.refreshRate),
            numericCast(specification.scaleFactor),
            specification.hiDPI,
            specification.hdrEnabled,
            displayGamut.rawValue,
            displayTransfer.rawValue
        )
    }

    @discardableResult
    public static func updateDisplay(
        clientIdentifier: String,
        logicalWidth: Int,
        logicalHeight: Int,
        refreshRate: Int,
        displayTransfer: MDKDisplayTransfer = .unknown
    ) -> Bool {
        MDKShimUpdateVirtualDisplay(
            clientIdentifier,
            numericCast(logicalWidth),
            numericCast(logicalHeight),
            numericCast(refreshRate),
            displayTransfer.rawValue
        )
    }

    @discardableResult
    public static func removeDisplay(clientIdentifier: String) -> Bool {
        MDKShimRemoveVirtualDisplay(clientIdentifier)
    }
}
