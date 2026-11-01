import SwiftUI

@main
struct PriceTrackerApp: App {
    init() {
        guard !AppGroup.isDemo else { return }
        PriceTrackerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
