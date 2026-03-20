import Foundation
import MacDisplayKitObjCShim

@objcMembers
public final class MDKFrameworkInfo: NSObject {
    public static func versionString() -> String {
        MDKShimVersionString() as String
    }

    public static func repositoryRootURL() -> URL {
        MDKShimRepositoryRootURL() as URL
    }

    public static func legacyRuntimeSourceRootURL() -> URL {
        MDKShimLegacyRuntimeSourceRootURL() as URL
    }

    public static func plannedModules() -> [String] {
        MDKShimPlannedModuleNames()
    }

    public static func implementationLanguages() -> [String] {
        ["Swift", "Objective-C++", "Metal"]
    }
}
