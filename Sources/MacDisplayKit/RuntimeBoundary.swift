import Foundation

public enum MDKResponsibilityBoundary {
    public static let frameworkOwns: [String] = [
        "virtual display lifecycle",
        "display mode and HDR metadata",
        "capture backend selection",
        "frame acquisition and diagnostics",
        "Metal and Objective-C++ interop shims",
    ]

    public static let consumerOwns: [String] = [
        "transport protocol",
        "session orchestration",
        "pairing and authentication",
        "application-specific policy",
        "mapping app state into MacDisplayKit inputs",
    ]
}
