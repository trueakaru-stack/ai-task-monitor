import SwiftUI

struct AITaskMonitorApp: App {
    @StateObject private var store = TaskStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Обновить задачи") { store.refresh() }.keyboardShortcut("r")
            }
        }
    }
}
