import Foundation
import SwiftUI

if CommandLine.arguments.contains("--cursor-focus-helper") {
    exit(MainActor.assumeIsolated { CursorIntegrationHarness.focusHelper() })
} else if let index = CommandLine.arguments.firstIndex(of: "--cursor-integration"), CommandLine.arguments.indices.contains(index + 1) {
    exit(MainActor.assumeIsolated { CursorIntegrationHarness.run(fixture: CommandLine.arguments[index + 1]) })
} else if CommandLine.arguments.contains("--claude-hook") {
    exit(ClaudeHook.run())
} else if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    exit(MainActor.assumeIsolated { SnapshotRenderer.run(outputDirectory: output) })
} else {
    AITaskMonitorApp.main()
}
