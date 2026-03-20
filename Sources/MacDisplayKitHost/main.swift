import AppKit
import MacDisplayKit

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        let frame = NSRect(x: 0, y: 0, width: 720, height: 340)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacDisplayKitHost"

        let title = label(
            frame: NSRect(x: 24, y: 212, width: 640, height: 64),
            font: .systemFont(ofSize: 20, weight: .semibold),
            text: "MacDisplayKit \(MDKFrameworkInfo.versionString())"
        )
        let runtime = label(
            frame: NSRect(x: 24, y: 128, width: 640, height: 56),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Implementation languages: \(MDKFrameworkInfo.implementationLanguages().joined(separator: ", "))"
        )
        let details = label(
            frame: NSRect(x: 24, y: 72, width: 640, height: 40),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Legacy runtime source root: \(MDKFrameworkInfo.legacyRuntimeSourceRootURL().path)"
        )

        window.contentView?.addSubview(title)
        window.contentView?.addSubview(runtime)
        window.contentView?.addSubview(details)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func label(frame: NSRect, font: NSFont, text: String) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = true
        label.font = font
        label.stringValue = text
        return label
    }
}

let app = NSApplication.shared
let delegate = HostAppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
