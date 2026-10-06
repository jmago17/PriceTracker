import SwiftUI
@preconcurrency import UserNotifications

@main
struct PriceTrackerApp: App {
    init() {
        guard !AppGroup.isDemo else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        PriceTrackerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
