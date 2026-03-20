import Foundation
import MacDisplayKit

private enum MDKHostCLICommand {
    case listDisplays
    case listTargets
    case benchmark(displayID: UInt32, targetIdentifier: String, intent: MDKCapturePlanIntent, json: Bool)
    case benchmarkMatrix(displayID: UInt32, intent: MDKCapturePlanIntent, json: Bool)
}

enum MDKHostCommandLine {
    static func runIfRequested(arguments: [String], controller: MDKHostBenchmarkController) -> Int32? {
        guard let command = parse(arguments: arguments) else {
            return nil
        }

        switch command {
        case .listDisplays:
            for display in controller.availableDisplays() {
                print("\(display.id)\t\(display.localizedName)")
            }
            return 0
        case .listTargets:
            for target in controller.availableTargets() {
                print("\(target.identifier)\t\(target.name)")
            }
            return 0
        case .benchmark(let displayID, let targetIdentifier, let intent, let json):
            guard let display = controller.display(id: displayID) else {
                fputs("Unknown display id: \(displayID)\n", stderr)
                return 64
            }
            guard let target = controller.target(identifier: targetIdentifier) else {
                fputs("Unknown target identifier: \(targetIdentifier)\n", stderr)
                return 64
            }

            let suite = controller.runBenchmark(display: display, target: target, intent: intent)
            if json {
                do {
                    let data = try MDKCaptureBenchmarkReport.jsonData(for: suite)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } catch {
                    fputs("Failed to encode benchmark report: \(error)\n", stderr)
                    return 1
                }
            } else {
                print(MDKHostBenchmarkFormatter.formatReport(for: suite))
            }

            return suite.assessment.passed ? 0 : 2
        case .benchmarkMatrix(let displayID, let intent, let json):
            guard let display = controller.display(id: displayID) else {
                fputs("Unknown display id: \(displayID)\n", stderr)
                return 64
            }

            let matrix = controller.runCaptureOnlyValidationMatrix(display: display, intent: intent)
            if json {
                do {
                    let data = try MDKCaptureBenchmarkReport.jsonData(for: matrix)
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } catch {
                    fputs("Failed to encode benchmark matrix report: \(error)\n", stderr)
                    return 1
                }
            } else {
                for suite in matrix.suites {
                    print(MDKHostBenchmarkFormatter.formatReport(for: suite))
                    print("")
                }
            }

            return matrix.passed ? 0 : 2
        }
    }

    private static func parse(arguments: [String]) -> MDKHostCLICommand? {
        let tokens = Array(arguments.dropFirst())
        guard !tokens.isEmpty else {
            return nil
        }

        if tokens.contains("--list-displays") {
            return .listDisplays
        }

        if tokens.contains("--list-targets") {
            return .listTargets
        }

        if let matrixDisplayIndex = tokens.firstIndex(of: "--benchmark-matrix-display"),
           tokens.indices.contains(matrixDisplayIndex + 1),
           let displayID = UInt32(tokens[matrixDisplayIndex + 1]) {
            let intent: MDKCapturePlanIntent = tokens.contains("--compare-backends")
                ? .compareBackends
                : .validateDefaultBackend
            let json = tokens.contains("--json")
            return .benchmarkMatrix(displayID: displayID, intent: intent, json: json)
        }

        guard let displayIndex = tokens.firstIndex(of: "--benchmark-display"),
              let targetIndex = tokens.firstIndex(of: "--benchmark-target"),
              tokens.indices.contains(displayIndex + 1),
              tokens.indices.contains(targetIndex + 1),
              let displayID = UInt32(tokens[displayIndex + 1]) else {
            return nil
        }

        let targetIdentifier = tokens[targetIndex + 1]
        let intent: MDKCapturePlanIntent = tokens.contains("--compare-backends")
            ? .compareBackends
            : .validateDefaultBackend
        let json = tokens.contains("--json")
        return .benchmark(
            displayID: displayID,
            targetIdentifier: targetIdentifier,
            intent: intent,
            json: json
        )
    }
}
