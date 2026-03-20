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
        MDKShimMicrophoneNames().map(MDKAudioInputDescriptor.init(name:))
    }

    public static var prefersScreenCaptureKitVideo: Bool {
        MDKShimVideoScreenCaptureKitPreferred()
    }

    public static var supportsScreenCaptureKitSystemAudio: Bool {
        MDKShimSystemAudioScreenCaptureKitSupported()
    }
}
