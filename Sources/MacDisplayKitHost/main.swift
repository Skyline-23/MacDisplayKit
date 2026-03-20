import AppKit
import MacDisplayKit

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let benchmarkController = MDKHostBenchmarkController()
    private var displays: [MDKDisplayDescriptor] = []
    private var targets: [MDKCaptureOptimizationTarget] = []
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let runButton = NSButton(frame: .zero)
    private let compareButton = NSButton(frame: .zero)
    private let resultView = NSTextView(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        let frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacDisplayKitHost"

        let title = label(
            frame: NSRect(x: 24, y: 552, width: 720, height: 32),
            font: .systemFont(ofSize: 20, weight: .semibold),
            text: "MacDisplayKit \(MDKFrameworkInfo.versionString())"
        )
        let runtime = label(
            frame: NSRect(x: 24, y: 520, width: 820, height: 24),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Implementation languages: \(MDKFrameworkInfo.implementationLanguages().joined(separator: ", "))"
        )
        let details = label(
            frame: NSRect(x: 24, y: 492, width: 820, height: 24),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            text: "Legacy runtime source root: \(MDKFrameworkInfo.legacyRuntimeSourceRootURL().path)"
        )
        let displayLabel = label(
            frame: NSRect(x: 24, y: 444, width: 120, height: 24),
            font: .systemFont(ofSize: 13, weight: .medium),
            text: "Display"
        )
        let targetLabel = label(
            frame: NSRect(x: 24, y: 404, width: 120, height: 24),
            font: .systemFont(ofSize: 13, weight: .medium),
            text: "Target"
        )

        displayPopup.frame = NSRect(x: 140, y: 440, width: 520, height: 30)
        targetPopup.frame = NSRect(x: 140, y: 400, width: 520, height: 30)

        runButton.frame = NSRect(x: 680, y: 438, width: 180, height: 32)
        runButton.bezelStyle = .rounded
        runButton.title = "Validate Default"
        runButton.target = self
        runButton.action = #selector(runDefaultBenchmark)

        compareButton.frame = NSRect(x: 680, y: 398, width: 180, height: 32)
        compareButton.bezelStyle = .rounded
        compareButton.title = "Compare Backends"
        compareButton.target = self
        compareButton.action = #selector(runComparisonBenchmark)

        let scrollView = NSScrollView(frame: NSRect(x: 24, y: 24, width: 836, height: 352))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultView.string = "Select a display and target, then run a benchmark."
        scrollView.documentView = resultView

        window.contentView?.addSubview(title)
        window.contentView?.addSubview(runtime)
        window.contentView?.addSubview(details)
        window.contentView?.addSubview(displayLabel)
        window.contentView?.addSubview(targetLabel)
        window.contentView?.addSubview(displayPopup)
        window.contentView?.addSubview(targetPopup)
        window.contentView?.addSubview(runButton)
        window.contentView?.addSubview(compareButton)
        window.contentView?.addSubview(scrollView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        loadSelections()
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

    private func loadSelections() {
        displays = benchmarkController.availableDisplays()
        targets = benchmarkController.availableTargets()

        displayPopup.removeAllItems()
        for display in displays {
            displayPopup.addItem(withTitle: "\(display.localizedName) (\(display.id))")
        }

        targetPopup.removeAllItems()
        for target in targets {
            targetPopup.addItem(withTitle: target.name)
        }

        runButton.isEnabled = !displays.isEmpty && !targets.isEmpty
        compareButton.isEnabled = runButton.isEnabled
        if displays.isEmpty || targets.isEmpty {
            resultView.string = "No benchmarkable displays or targets are available."
        }
    }

    @objc
    private func runDefaultBenchmark() {
        runBenchmark(intent: .validateDefaultBackend)
    }

    @objc
    private func runComparisonBenchmark() {
        runBenchmark(intent: .compareBackends)
    }

    private func runBenchmark(intent: MDKCapturePlanIntent) {
        guard
            displays.indices.contains(displayPopup.indexOfSelectedItem),
            targets.indices.contains(targetPopup.indexOfSelectedItem)
        else {
            resultView.string = "Select a display and target first."
            return
        }

        let display = displays[displayPopup.indexOfSelectedItem]
        let target = targets[targetPopup.indexOfSelectedItem]

        runButton.isEnabled = false
        compareButton.isEnabled = false
        resultView.string = "Running \(intent == .compareBackends ? "comparison" : "default") benchmark for \(display.localizedName) ..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            let suite = self.benchmarkController.runBenchmark(
                display: display,
                target: target,
                intent: intent
            )
            let report = self.formatReport(for: suite)

            DispatchQueue.main.async {
                self.resultView.string = report
                self.runButton.isEnabled = true
                self.compareButton.isEnabled = true
            }
        }
    }

    private func formatReport(for suite: MDKCaptureBenchmarkSuiteResult) -> String {
        var lines: [String] = []
        lines.append("Display: \(suite.plan.display.localizedName) (\(suite.plan.display.id))")
        lines.append("Target: \(suite.plan.target.name)")
        lines.append("Intent: \(suite.plan.intent == .compareBackends ? "compare-backends" : "validate-default-backend")")
        lines.append("Sample duration: \(String(format: "%.2fs", suite.sampleDuration))")
        lines.append("Pixel format: \(String(format: "0x%08X", suite.pixelFormat))")
        lines.append("")

        for measurement in suite.measurements {
            lines.append("Backend: \(backendName(measurement.backend))")
            lines.append("Available: \(measurement.available ? "yes" : "no")")
            lines.append("Reason: \(measurement.reason)")
            if let result = measurement.result {
                lines.append("Observed FPS: \(String(format: "%.2f", result.observedFrameRate))")
                lines.append("Delivered frames: \(result.deliveredFrameCount)")
                lines.append("Skipped callbacks: \(result.skippedFrameCount)")
                lines.append("Delivery ratio: \(String(format: "%.3f", result.deliveryRatio))")
                if let firstFrameLatency = result.firstFrameLatency {
                    lines.append("First frame latency: \(String(format: "%.3fs", firstFrameLatency))")
                }
            } else if let errorDescription = measurement.errorDescription {
                lines.append("Error: \(errorDescription)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func backendName(_ backend: MDKCaptureBackend) -> String {
        switch backend {
        case .avFoundation:
            return "AVFoundation"
        case .cgDisplayStream:
            return "CGDisplayStream"
        }
    }
}

let app = NSApplication.shared
let delegate = HostAppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
