// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDisplayKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacDisplayCaptureKit",
            type: .dynamic,
            targets: ["MacDisplayCaptureKit"]
        ),
        .library(
            name: "MacDisplayVirtualDisplayKit",
            type: .dynamic,
            targets: ["MacDisplayVirtualDisplayKit"]
        ),
        .library(
            name: "MacDisplayKit",
            type: .dynamic,
            targets: ["MacDisplayKit"]
        )
    ],
    targets: [
        .target(
            name: "MacDisplayKitObjCShim",
            path: "Sources/MacDisplayKitObjCShim",
            exclude: [
                "LegacyRuntime"
            ],
            publicHeadersPath: "Public",
            cSettings: [
                .headerSearchPath("Public"),
                .headerSearchPath("Internal"),
                .headerSearchPath("LegacyRuntime"),
                .headerSearchPath("LegacyRuntime/Capture"),
                .headerSearchPath("LegacyRuntime/third-party/TPCircularBuffer"),
                .headerSearchPath("LegacyRuntime/VirtualDisplay")
            ],
            cxxSettings: [
                .headerSearchPath("Public"),
                .headerSearchPath("Internal"),
                .headerSearchPath("LegacyRuntime"),
                .headerSearchPath("LegacyRuntime/Capture"),
                .headerSearchPath("LegacyRuntime/third-party/TPCircularBuffer"),
                .headerSearchPath("LegacyRuntime/VirtualDisplay")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface")
            ]
        ),
        .target(
            name: "MacDisplayCaptureKit",
            dependencies: ["MacDisplayKitObjCShim"],
            path: "Sources/MacDisplayCaptureKit",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "MacDisplayVirtualDisplayKit",
            dependencies: ["MacDisplayKitObjCShim"],
            path: "Sources/MacDisplayVirtualDisplayKit",
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "MacDisplayKit",
            dependencies: [
                "MacDisplayKitObjCShim",
                "MacDisplayCaptureKit",
                "MacDisplayVirtualDisplayKit"
            ],
            path: "Sources/MacDisplayKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "MacDisplayKitTests",
            dependencies: [
                "MacDisplayKit",
                "MacDisplayCaptureKit"
            ],
            path: "Tests/MacDisplayKitTests"
        )
    ],
    cxxLanguageStandard: .gnucxx2b
)
