// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [:],
    baseSettings: .settings(
        base: [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES"
        ]
    )
)
#endif

let package = Package(
    name: "MacDisplayKit",
    dependencies: []
)
