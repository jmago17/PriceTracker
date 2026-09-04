import Foundation

enum AppGroup {
    static let identifier = "group.com.maromeapps.PriceTracker"

    /// Root shared container. Crashes if the App Group entitlement is missing or
    /// misconfigured — that is a build/signing bug, not a runtime condition to recover from.
    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container '\(identifier)' is unavailable — check the entitlement.")
        }
        return url
    }

    static var itemsFileURL: URL {
        containerURL.appendingPathComponent("items.json")
    }

    static var alertsFileURL: URL {
        containerURL.appendingPathComponent("alerts.json")
    }
}
