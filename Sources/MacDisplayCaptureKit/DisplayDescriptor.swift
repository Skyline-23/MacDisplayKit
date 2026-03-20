import Foundation

@objcMembers
public final class MDKDisplayDescriptor: NSObject {
    public let id: UInt32
    public let name: String
    public let localizedName: String

    public init(id: UInt32, name: String, localizedName: String) {
        self.id = id
        self.name = name
        self.localizedName = localizedName
        super.init()
    }
}
