import Metal

public enum MDKCaptureBenchmarkProcessingMode: String, CaseIterable, Codable, Sendable {
    case none
    case metalBind = "metal-bind"
    case metalCopy = "metal-copy"

    public var localizedName: String {
        switch self {
        case .none:
            return "none"
        case .metalBind:
            return "metal-bind"
        case .metalCopy:
            return "metal-copy"
        }
    }
}

public enum MDKCaptureFrameProcessingError: Error, LocalizedError, Equatable {
    case surfaceUnavailable
    case metalDeviceUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case blitEncoderUnavailable
    case textureBindingFailed(plane: Int)
    case destinationTextureCreationFailed(plane: Int)

    public var errorDescription: String? {
        switch self {
        case .surfaceUnavailable:
            return "The capture frame does not carry an IOSurface-backed surface."
        case .metalDeviceUnavailable:
            return "A Metal device is not available on this host."
        case .commandQueueUnavailable:
            return "A Metal command queue is not available on this host."
        case .commandBufferUnavailable:
            return "Unable to create a Metal command buffer."
        case .blitEncoderUnavailable:
            return "Unable to create a Metal blit encoder."
        case .textureBindingFailed(let plane):
            return "Unable to bind capture plane \(plane) into a Metal texture."
        case .destinationTextureCreationFailed(let plane):
            return "Unable to create a Metal destination texture for plane \(plane)."
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

public final class MDKNoopCaptureFrameProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    public init() {}

    public func process(frame: MDKCaptureFrame) throws {
        _ = frame
    }
}

private struct MDKMetalBoundPlane {
    let descriptor: MDKMetalPlaneDescriptor
    let texture: any MTLTexture
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
        let boundPlanes = try makeBoundPlanes(frame: frame)
        return MDKMetalBoundFrame(
            surfaceID: frame.surfaceID,
            planeDescriptors: boundPlanes.map(\.descriptor)
        )
    }

    fileprivate func makeBoundPlanes(frame: MDKCaptureFrame) throws -> [MDKMetalBoundPlane] {
        guard let surface = frame.surface else {
            throw MDKCaptureFrameProcessingError.surfaceUnavailable
        }

        let planeCount = max(surface.planeCount, 1)
        var boundPlanes: [MDKMetalBoundPlane] = []
        boundPlanes.reserveCapacity(planeCount)

        for plane in 0..<planeCount {
            let descriptor = try surface.metalPlaneDescriptor(for: plane)
            guard let texture = try surface.makeMetalTexture(device: device, plane: plane) else {
                throw MDKCaptureFrameProcessingError.textureBindingFailed(plane: plane)
            }
            boundPlanes.append(
                MDKMetalBoundPlane(
                    descriptor: descriptor,
                    texture: texture
                )
            )
        }

        return boundPlanes
    }
}

private struct MDKMetalDestinationKey: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    let plane: Int
}

public final class MDKMetalTextureCopyProcessor: MDKCaptureFrameProcessing, @unchecked Sendable {
    private let bindingProcessor: MDKMetalTextureBindingProcessor
    private let commandQueue: any MTLCommandQueue
    private let inflightSemaphore: DispatchSemaphore
    private let cacheLock = NSLock()
    private var destinationTextures: [MDKMetalDestinationKey: any MTLTexture] = [:]

    public init(
        device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        maxInflightCommandBuffers: Int = 8
    ) throws {
        guard let device else {
            throw MDKCaptureFrameProcessingError.metalDeviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MDKCaptureFrameProcessingError.commandQueueUnavailable
        }
        self.bindingProcessor = try MDKMetalTextureBindingProcessor(device: device)
        self.commandQueue = commandQueue
        self.inflightSemaphore = DispatchSemaphore(value: max(maxInflightCommandBuffers, 1))
    }

    public func process(frame: MDKCaptureFrame) throws {
        let boundPlanes = try bindingProcessor.makeBoundPlanes(frame: frame)
        try copy(boundPlanes: boundPlanes)
    }

    private func copy(boundPlanes: [MDKMetalBoundPlane]) throws {
        inflightSemaphore.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            throw MDKCaptureFrameProcessingError.commandBufferUnavailable
        }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            inflightSemaphore.signal()
            throw MDKCaptureFrameProcessingError.blitEncoderUnavailable
        }

        do {
            for boundPlane in boundPlanes {
                let destination = try destinationTexture(for: boundPlane.descriptor)
                let copySize = MTLSize(width: boundPlane.descriptor.width, height: boundPlane.descriptor.height, depth: 1)
                blitEncoder.copy(
                    from: boundPlane.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: copySize,
                    to: destination,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
        } catch {
            blitEncoder.endEncoding()
            inflightSemaphore.signal()
            throw error
        }

        blitEncoder.endEncoding()
        commandBuffer.addCompletedHandler { [inflightSemaphore] _ in
            inflightSemaphore.signal()
        }
        commandBuffer.commit()
    }

    private func destinationTexture(for descriptor: MDKMetalPlaneDescriptor) throws -> any MTLTexture {
        let key = MDKMetalDestinationKey(
            width: descriptor.width,
            height: descriptor.height,
            pixelFormat: descriptor.pixelFormat,
            plane: descriptor.plane
        )

        cacheLock.lock()
        if let existing = destinationTextures[key] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.pixelFormat,
            width: descriptor.width,
            height: descriptor.height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let texture = commandQueue.device.makeTexture(descriptor: textureDescriptor) else {
            throw MDKCaptureFrameProcessingError.destinationTextureCreationFailed(plane: descriptor.plane)
        }

        cacheLock.lock()
        destinationTextures[key] = texture
        cacheLock.unlock()
        return texture
    }
}
