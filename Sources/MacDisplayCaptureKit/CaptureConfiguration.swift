import Foundation

@objc
public enum MDKCaptureBackend: Int {
    case avFoundation = 0
    case cgDisplayStream = 1
}

@objc
public enum MDKDynamicRangeMode: Int {
    case sdr = 0
    case hdrCanonical = 1
    case hdrLocal = 2
}

@objcMembers
public final class MDKCaptureConfiguration: NSObject, NSCopying {
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let pixelFormat: UInt32
    public let backend: MDKCaptureBackend
    public let dynamicRangeMode: MDKDynamicRangeMode

    public init(
        displayID: UInt32,
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: UInt32,
        backend: MDKCaptureBackend,
        dynamicRangeMode: MDKDynamicRangeMode
    ) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.backend = backend
        self.dynamicRangeMode = dynamicRangeMode
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        MDKCaptureConfiguration(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat,
            backend: backend,
            dynamicRangeMode: dynamicRangeMode
        )
    }
}
