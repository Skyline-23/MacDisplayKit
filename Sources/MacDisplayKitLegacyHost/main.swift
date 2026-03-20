import AppKit
import MacDisplayKit

final class LegacyHostAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        let frame = NSRect(x: 0, y: 0, width: 860, height: 440)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacDisplayKitLegacyHost"

        let title = label(
            frame: NSRect(x: 24, y: 320, width: 760, height: 32),
            font: .systemFont(ofSize: 22, weight: .semibold),
            text: "Legacy runtime host"
        )
        let subtitle = label(
            frame: NSRect(x: 24, y: 248, width: 780, height: 52),
            font: .systemFont(ofSize: 13, weight: .regular),
            text: "This app is the transitional runtime target for imported macOS C/C++/Objective-C++ code while framework-owned Swift modules replace it."
        )
        let snapshot = label(
            frame: NSRect(x: 24, y: 184, width: 780, height: 40),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Runtime source root: \(MDKFrameworkInfo.legacyRuntimeSourceRootURL().path)"
        )
        let planned = label(
            frame: NSRect(x: 24, y: 76, width: 780, height: 92),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Planned framework modules:\n- \(MDKFrameworkInfo.plannedModules().joined(separator: "\n- "))"
        )

        window.contentView?.addSubview(title)
        window.contentView?.addSubview(subtitle)
        window.contentView?.addSubview(snapshot)
        window.contentView?.addSubview(planned)
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
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        return label
    }
}

let app = NSApplication.shared
let delegate = LegacyHostAppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
