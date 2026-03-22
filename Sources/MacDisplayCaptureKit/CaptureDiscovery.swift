import Foundation
import MacDisplayKitObjCShim

@objcMembers
public final class MDKCaptureDiscovery: NSObject {
    public static func displays() -> [MDKDisplayDescriptor] {
        MDKShimListDisplays().compactMap { entry in
            guard
                let idValue = entry["id"] as? NSNumber,
                let name = entry["name"] as? String,
                let localizedName = entry["displayName"] as? String
            else {
                return nil
            }

            return MDKDisplayDescriptor(
                id: idValue.uint32Value,
                name: name,
                localizedName: localizedName
            )
        }
    }

    public static func displayName(for displayID: UInt32) -> String? {
        MDKShimDisplayName(UInt(displayID))
    }

    public static func microphoneInputs() -> [MDKAudioInputDescriptor] {
        MDKShimMicrophoneDescriptors().compactMap { entry in
            guard let id = entry["id"], let name = entry["name"] else {
                return nil
            }

            return MDKAudioInputDescriptor(id: id, name: name)
        }
    }
}
