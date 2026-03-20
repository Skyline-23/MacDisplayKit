import Metal

public enum MDKCaptureFrameProcessingError: Error, LocalizedError, Equatable {
    case surfaceUnavailable
    case metalDeviceUnavailable
    case textureBindingFailed(plane: Int)

    public var errorDescription: String? {
        switch self {
        case .surfaceUnavailable:
            return "The capture frame does not carry an IOSurface-backed surface."
        case .metalDeviceUnavailable:
            return "A Metal device is not available on this host."
        case .textureBindingFailed(let plane):
            return "Unable to bind capture plane \(plane) into a Metal texture."
        }
    }
}

@objcMembers
public final class MDKMetalBoundFrame: NSObject {
    public let surfaceID: UInt32
    public let planeDescriptors: [MDKMetalPlaneDescriptor]

    public init(surfaceID: UInt32, planeDescriptors: [MDKMetalPlaneDescriptor]) {
        self.surfaceID = surfaceID
        self.planeDescriptors = planeDescriptors
        super.init()
    }
}

protocol MDKCaptureFrameProcessing: AnyObject, Sendable {
    func process(frame: MDKCaptureFrame) throws
}

public final class MDKMetalTextureBindingProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    private let device: any MTLDevice

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw MDKCaptureFrameProcessingError.metalDeviceUnavailable
        }
        self.device = device
    }

    public func process(frame: MDKCaptureFrame) throws {
        _ = try bind(frame: frame)
    }

    public func bind(frame: MDKCaptureFrame) throws -> MDKMetalBoundFrame {
        guard let surface = frame.surface else {
            throw MDKCaptureFrameProcessingError.surfaceUnavailable
        }

        let planeCount = max(surface.planeCount, 1)
        var descriptors: [MDKMetalPlaneDescriptor] = []
        descriptors.reserveCapacity(planeCount)

        for plane in 0..<planeCount {
            let descriptor = try surface.metalPlaneDescriptor(for: plane)
            guard try surface.makeMetalTexture(device: device, plane: plane) != nil else {
                throw MDKCaptureFrameProcessingError.textureBindingFailed(plane: plane)
            }
            descriptors.append(descriptor)
        }

        return MDKMetalBoundFrame(surfaceID: frame.surfaceID, planeDescriptors: descriptors)
    }
}
