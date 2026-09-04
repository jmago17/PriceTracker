import SwiftUI
@preconcurrency import UserNotifications

@main
struct PriceTrackerApp: App {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
