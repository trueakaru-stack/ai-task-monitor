import Foundation
import SwiftUI

if CommandLine.arguments.contains("--claude-hook") {
    exit(ClaudeHook.run())
} else if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) {
    exit(SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)))
} else {
    AITaskMonitorApp.main()
}
