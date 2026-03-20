import Foundation
import Darwin

public struct MDKScreenCaptureKitRuntimeClassInventory: Codable, Equatable, Sendable {
    public let className: String
    public let loaded: Bool
    public let filteredMethods: [String]
    public let filteredMethodCount: Int

    public init(
        className: String,
        loaded: Bool,
        filteredMethods: [String],
        filteredMethodCount: Int
    ) {
        self.className = className
        self.loaded = loaded
        self.filteredMethods = filteredMethods
        self.filteredMethodCount = filteredMethodCount
    }

    init(shimDictionary: NSDictionary) throws {
        guard let className = shimDictionary["className"] as? String else {
            throw MDKScreenCaptureKitRuntimeInventoryError.invalidShimPayload
        }

        self.init(
            className: className,
            loaded: (shimDictionary["loaded"] as? NSNumber)?.boolValue ?? false,
            filteredMethods: shimDictionary["filteredMethods"] as? [String] ?? [],
            filteredMethodCount: (shimDictionary["filteredMethodCount"] as? NSNumber)?.intValue ?? 0
        )
    }
}

public struct MDKScreenCaptureKitRuntimeInventory: Codable, Equatable, Sendable {
    public let classes: [MDKScreenCaptureKitRuntimeClassInventory]
    public let screenCaptureKitSymbols: [String: Bool]
    public let cmCaptureSymbols: [String: Bool]
    public let notes: [String]

    public init(
        classes: [MDKScreenCaptureKitRuntimeClassInventory],
        screenCaptureKitSymbols: [String: Bool],
        cmCaptureSymbols: [String: Bool],
        notes: [String]
    ) {
        self.classes = classes
        self.screenCaptureKitSymbols = screenCaptureKitSymbols
        self.cmCaptureSymbols = cmCaptureSymbols
        self.notes = notes
    }

    init(shimDictionary: NSDictionary) throws {
        let classDictionaries = shimDictionary["classes"] as? [NSDictionary] ?? []
        let classes = try classDictionaries.map(MDKScreenCaptureKitRuntimeClassInventory.init(shimDictionary:))

        let screenCaptureKitSymbols = (shimDictionary["screenCaptureKitSymbols"] as? [String: NSNumber] ?? [:])
            .mapValues(\.boolValue)
        let cmCaptureSymbols = (shimDictionary["cmCaptureSymbols"] as? [String: NSNumber] ?? [:])
            .mapValues(\.boolValue)

        self.init(
            classes: classes,
            screenCaptureKitSymbols: screenCaptureKitSymbols,
            cmCaptureSymbols: cmCaptureSymbols,
            notes: shimDictionary["notes"] as? [String] ?? []
        )
    }
}

public enum MDKScreenCaptureKitRuntimeInventoryError: Error, Equatable, Sendable {
    case unavailable
    case invalidShimPayload
}

public enum MDKScreenCaptureKitRuntimeInspector {
    public static func inspect() throws -> MDKScreenCaptureKitRuntimeInventory {
        var nsError: NSError?
        guard let payload = MDKScreenCaptureKitRuntimeShim.function?(&nsError) else {
            if let nsError {
                throw nsError
            }
            throw MDKScreenCaptureKitRuntimeInventoryError.unavailable
        }

        return try MDKScreenCaptureKitRuntimeInventory(shimDictionary: payload)
    }
}

private enum MDKScreenCaptureKitRuntimeShim {
    typealias Function = @convention(c) (UnsafeMutablePointer<NSError?>?) -> NSDictionary?

    static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        guard let symbol = dlsym(handle, "MDKShimVideoInspectScreenCaptureKitRuntime") else {
            return nil
        }

        return unsafeBitCast(symbol, to: Function.self)
    }()
}
