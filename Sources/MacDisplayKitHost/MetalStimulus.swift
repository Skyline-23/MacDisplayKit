import AppKit
import Metal
import MetalKit

final class MDKHostMetalStimulus: NSObject, MTKViewDelegate {
    private let window: NSWindow
    private let view: MTKView
    private let commandQueue: MTLCommandQueue
    private let startTime = CACurrentMediaTime()

    init?(displayID: UInt32) {
        guard
            let screen = NSScreen.screens.first(where: { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return false
                }
                return number.uint32Value == displayID
            }),
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .normal
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let view = MTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoresizingMask = [.width, .height]

        self.window = window
        self.view = view
        self.commandQueue = commandQueue

        super.init()

        view.delegate = self
        window.contentView = view
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        view.isPaused = true
        window.orderOut(nil)
        window.close()
    }

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        let r = 0.5 + 0.5 * sin(elapsed * 4.0)
        let g = 0.5 + 0.5 * sin(elapsed * 6.0 + .pi / 3.0)
        let b = 0.5 + 0.5 * sin(elapsed * 8.0 + .pi / 1.7)
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = (view, size)
    }
}
