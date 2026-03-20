import Foundation

@objcMembers
public final class MDKVirtualDisplaySpecification: NSObject, NSCopying {
    public let clientIdentifier: String
    public let clientName: String
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let refreshRate: Int
    public let scaleFactor: Int
    public let hiDPI: Bool
    public let hdrEnabled: Bool

    public init(
        clientIdentifier: String,
        clientName: String,
        logicalWidth: Int,
        logicalHeight: Int,
        refreshRate: Int,
        scaleFactor: Int,
        hiDPI: Bool,
        hdrEnabled: Bool
    ) {
        self.clientIdentifier = clientIdentifier
        self.clientName = clientName
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRate = refreshRate
        self.scaleFactor = scaleFactor
        self.hiDPI = hiDPI
        self.hdrEnabled = hdrEnabled
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        MDKVirtualDisplaySpecification(
            clientIdentifier: clientIdentifier,
            clientName: clientName,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            refreshRate: refreshRate,
            scaleFactor: scaleFactor,
            hiDPI: hiDPI,
            hdrEnabled: hdrEnabled
        )
    }
}
