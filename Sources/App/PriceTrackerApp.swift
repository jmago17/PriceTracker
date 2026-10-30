import SwiftUI
import BackgroundTasks

@main
struct PriceTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        guard !AppGroup.isDemo else { return }
        PriceTrackerShortcuts.updateAppShortcutParameters()
    }

    /// The server checks prices and sends the alerts; the on-device daily task
    /// and Shortcuts bridge only run outside remote mode.
    private var runsLocalChecks: Bool { !AppGroup.isDemo && !AppEnvironment.shared.isRemote }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    guard runsLocalChecks else { return }
                    await ShortcutBridgeSettings.shared.restore()
                }
        }
        .backgroundTask(.appRefresh(DailyRefreshSettings.taskID)) {
            await DailyRefreshSettings.shared.run()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && runsLocalChecks { DailyRefreshSettings.shared.schedule() }
            if phase == .active && runsLocalChecks {
                Task { await ShortcutBridgeSettings.shared.restore() }
            }
        }
    }
}
