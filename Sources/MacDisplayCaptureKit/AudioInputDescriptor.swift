import Foundation

@objcMembers
public final class MDKAudioInputDescriptor: NSObject {
    public let name: String

    public init(name: String) {
        self.name = name
        super.init()
    }
}
