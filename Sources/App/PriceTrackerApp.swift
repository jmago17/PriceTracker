import SwiftUI
import BackgroundTasks

@main
struct PriceTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        guard !AppGroup.isDemo else { return }
        PriceTrackerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    guard !AppGroup.isDemo else { return }
                    await ShortcutBridgeSettings.shared.restore()
                }
        }
        .backgroundTask(.appRefresh(DailyRefreshSettings.taskID)) {
            await DailyRefreshSettings.shared.run()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !AppGroup.isDemo { DailyRefreshSettings.shared.schedule() }
            if phase == .active && !AppGroup.isDemo {
                Task { await ShortcutBridgeSettings.shared.restore() }
            }
        }
    }
}
