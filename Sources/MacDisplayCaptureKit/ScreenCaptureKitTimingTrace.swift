import Foundation
import Darwin

public typealias MDKScreenCaptureKitTimingTrace = MDKScreenCaptureKitProxyHandshakeTrace

public enum MDKScreenCaptureKitTimingTracer {
    public static func trace(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitTimingTrace {
        var nsError: NSError?
        guard let payload = MDKScreenCaptureKitTimingShim.function?(
            UInt(displayID),
            sampleDuration,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKScreenCaptureKitProxyHandshakeTraceError.unavailable
        }

        return try MDKScreenCaptureKitTimingTrace(shimDictionary: payload)
    }
}

private enum MDKScreenCaptureKitTimingShim {
    typealias Function =
        @convention(c) (UInt, TimeInterval, UnsafeMutablePointer<NSError?>?) -> NSDictionary?

    static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        guard let symbol = dlsym(handle, "MDKShimVideoTraceScreenCaptureKitTiming") else {
            return nil
        }

        return unsafeBitCast(symbol, to: Function.self)
    }()
}
