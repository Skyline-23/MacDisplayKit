import ProjectDescription

let baseSettings: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++23",
    "CLANG_ENABLE_MODULES": "YES",
    "ENABLE_TESTING_SEARCH_PATHS": "YES",
    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": "6C922D256U",
    "MACOSX_DEPLOYMENT_TARGET": "15.0"
]

let project = Project(
    name: "MacDisplayKit",
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "MacDisplayCaptureKit",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.skyline23.MacDisplayCaptureKit",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Sources/MacDisplayCaptureKit/**"
            ],
            dependencies: [
                .target(name: "MacDisplayKitObjCShim")
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayCaptureKit",
                    "DEFINES_MODULE": "YES"
                ]
            )
        ),
        .target(
            name: "MacDisplayVirtualDisplayKit",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.skyline23.MacDisplayVirtualDisplayKit",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Sources/MacDisplayVirtualDisplayKit/**"
            ],
            dependencies: [
                .target(name: "MacDisplayKitObjCShim")
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayVirtualDisplayKit",
                    "DEFINES_MODULE": "YES"
                ]
            )
        ),
        .target(
            name: "MacDisplayKitLegacyHost",
            destinations: .macOS,
            product: .app,
            bundleId: "com.skyline23.MacDisplayKitLegacyHost",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "MacDisplayKitLegacyHost",
                    "LSMinimumSystemVersion": "15.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "NSPrincipalClass": "NSApplication"
                ]
            ),
            sources: [
                "Sources/MacDisplayKitLegacyHost/**"
            ],
            dependencies: [
                .target(name: "MacDisplayKit")
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayKitLegacyHost",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)",
                        "$(SRCROOT)/Sources/MacDisplayKitObjCShim/LegacyRuntime"
                    ]
                ]
            )
        ),
        .target(
            name: "MacDisplayKitObjCShim",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.skyline23.MacDisplayKitObjCShim",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Sources/MacDisplayKitObjCShim/Public/**/*.{h,m,mm,c,cpp}",
                "Sources/MacDisplayKitObjCShim/Internal/**/*.{h,m,mm,c,cpp}"
            ],
            headers: .headers(
                public: "Sources/MacDisplayKitObjCShim/Public/**",
                private: "Sources/MacDisplayKitObjCShim/Internal/**"
            ),
            dependencies: [
                .sdk(name: "AVFoundation", type: .framework),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "CoreAudio", type: .framework),
                .sdk(name: "CoreMedia", type: .framework),
                .sdk(name: "CoreGraphics", type: .framework),
                .sdk(name: "CoreVideo", type: .framework),
                .sdk(name: "Foundation", type: .framework),
                .sdk(name: "ScreenCaptureKit", type: .framework)
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayKitObjCShim",
                    "DEFINES_MODULE": "YES",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Sources/MacDisplayKitObjCShim/LegacyRuntime",
                        "$(SRCROOT)/Sources/MacDisplayKitObjCShim/LegacyRuntime/Capture",
                        "$(SRCROOT)/Sources/MacDisplayKitObjCShim/LegacyRuntime/third-party/TPCircularBuffer",
                        "$(SRCROOT)/Sources/MacDisplayKitObjCShim/LegacyRuntime/VirtualDisplay"
                    ],
                    "SKIP_INSTALL": "YES"
                ]
            )
        ),
        .target(
            name: "MacDisplayKit",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.skyline23.MacDisplayKit",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Sources/MacDisplayKit/**"
            ],
            dependencies: [
                .target(name: "MacDisplayKitObjCShim"),
                .target(name: "MacDisplayCaptureKit"),
                .target(name: "MacDisplayVirtualDisplayKit")
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayKit",
                    "DEFINES_MODULE": "YES"
                ]
            )
        ),
        .target(
            name: "MacDisplayKitHost",
            destinations: .macOS,
            product: .app,
            bundleId: "com.skyline23.MacDisplayKitHost",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "MacDisplayKitHost",
                    "LSMinimumSystemVersion": "15.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "NSPrincipalClass": "NSApplication"
                ]
            ),
            sources: [
                "Sources/MacDisplayKitHost/**"
            ],
            dependencies: [
                .target(name: "MacDisplayKit")
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "MacDisplayKitHost",
                    "GENERATE_INFOPLIST_FILE": "YES"
                ]
            )
        ),
        .target(
            name: "MacDisplayKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.skyline23.MacDisplayKitTests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Tests/MacDisplayKitTests/**/*.{swift,m,mm,c,cpp}"
            ],
            dependencies: [
                .target(name: "MacDisplayKit")
            ]
        )
    ],
    schemes: [
        .scheme(
            name: "MacDisplayKitTests",
            shared: true,
            buildAction: .buildAction(targets: [
                "MacDisplayKit",
                "MacDisplayKitTests"
            ]),
            testAction: .targets([
                .testableTarget(target: "MacDisplayKitTests")
            ])
        )
    ]
)
