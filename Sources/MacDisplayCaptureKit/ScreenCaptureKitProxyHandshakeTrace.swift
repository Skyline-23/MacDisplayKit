import Foundation
import Darwin

public struct MDKScreenCaptureKitProxyHandshakeStep: Codable, Equatable, Sendable {
    public let name: String
    public let selector: String?
    public let symbol: String?
    public let status: Int32?
    public let succeeded: Bool?
    public let notes: [String]

    public init(
        name: String,
        selector: String?,
        symbol: String?,
        status: Int32?,
        succeeded: Bool?,
        notes: [String]
    ) {
        self.name = name
        self.selector = selector
        self.symbol = symbol
        self.status = status
        self.succeeded = succeeded
        self.notes = notes
    }

    init(shimDictionary: NSDictionary) throws {
        guard let name = shimDictionary["name"] as? String else {
            throw MDKScreenCaptureKitProxyHandshakeTraceError.invalidShimPayload
        }

        self.init(
            name: name,
            selector: shimDictionary["selector"] as? String,
            symbol: shimDictionary["symbol"] as? String,
            status: (shimDictionary["status"] as? NSNumber)?.int32Value,
            succeeded: (shimDictionary["succeeded"] as? NSNumber)?.boolValue,
            notes: shimDictionary["notes"] as? [String] ?? []
        )
    }
}

public struct MDKScreenCaptureKitProxyHandshakeTrace: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let sampleDuration: TimeInterval
    public let status: Int32
    public let succeeded: Bool
    public let streamID: String?
    public let filterID: String?
    public let selectors: [String]
    public let symbols: [String]
    public let steps: [MDKScreenCaptureKitProxyHandshakeStep]
    public let notes: [String]

    public init(
        displayID: UInt32,
        sampleDuration: TimeInterval,
        status: Int32,
        succeeded: Bool,
        streamID: String?,
        filterID: String?,
        selectors: [String],
        symbols: [String],
        steps: [MDKScreenCaptureKitProxyHandshakeStep],
        notes: [String]
    ) {
        self.displayID = displayID
        self.sampleDuration = sampleDuration
        self.status = status
        self.succeeded = succeeded
        self.streamID = streamID
        self.filterID = filterID
        self.selectors = selectors
        self.symbols = symbols
        self.steps = steps
        self.notes = notes
    }

    init(shimDictionary: NSDictionary) throws {
        guard
            let displayIDNumber = shimDictionary["displayID"] as? NSNumber,
            let sampleDurationNumber = shimDictionary["sampleDuration"] as? NSNumber,
            let statusNumber = shimDictionary["status"] as? NSNumber,
            let succeededNumber = shimDictionary["succeeded"] as? NSNumber
        else {
            throw MDKScreenCaptureKitProxyHandshakeTraceError.invalidShimPayload
        }

        let stepDictionaries = shimDictionary["steps"] as? [NSDictionary] ?? []
        let steps = try stepDictionaries.map(MDKScreenCaptureKitProxyHandshakeStep.init(shimDictionary:))

        self.init(
            displayID: displayIDNumber.uint32Value,
            sampleDuration: sampleDurationNumber.doubleValue,
            status: statusNumber.int32Value,
            succeeded: succeededNumber.boolValue,
            streamID: shimDictionary["streamID"] as? String,
            filterID: shimDictionary["filterID"] as? String,
            selectors: shimDictionary["selectors"] as? [String] ?? [],
            symbols: shimDictionary["symbols"] as? [String] ?? [],
            steps: steps,
            notes: shimDictionary["notes"] as? [String] ?? []
        )
    }
}

public enum MDKScreenCaptureKitProxyHandshakeTraceError: Error, Equatable, Sendable {
    case unavailable
    case invalidShimPayload
}

public enum MDKScreenCaptureKitProxyHandshakeTracer {
    public static func trace(
        displayID: UInt32,
        sampleDuration: TimeInterval
    ) throws -> MDKScreenCaptureKitProxyHandshakeTrace {
        var nsError: NSError?
        guard let payload = MDKScreenCaptureKitProxyHandshakeShim.function?(
            UInt(displayID),
            sampleDuration,
            &nsError
        ) else {
            if let nsError {
                throw nsError
            }
            throw MDKScreenCaptureKitProxyHandshakeTraceError.unavailable
        }

        return try MDKScreenCaptureKitProxyHandshakeTrace(shimDictionary: payload)
    }
}

private enum MDKScreenCaptureKitProxyHandshakeShim {
    typealias Function =
        @convention(c) (UInt, TimeInterval, UnsafeMutablePointer<NSError?>?) -> NSDictionary?

    static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        guard let symbol = dlsym(handle, "MDKShimVideoTraceScreenCaptureKitProxyHandshake") else {
            return nil
        }

        return unsafeBitCast(symbol, to: Function.self)
    }()
}
