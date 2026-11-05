import SwiftUI

struct AITaskMonitorApp: App {
    @StateObject private var store = TaskStore(enableUpdateChecks: true, enableClaudeRetention: true, enableExternalProviders: true, enableCodexCloud: true)

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button(tr("Обновить задачи", "Refresh tasks")) { store.refresh() }.keyboardShortcut("r")
            }
        }
    }
}
