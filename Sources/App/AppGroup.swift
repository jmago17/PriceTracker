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

    static var databaseURL: URL {
        containerURL.appendingPathComponent("catalog.sqlite")
    }

    static var alertsFileURL: URL {
        containerURL.appendingPathComponent("alerts.json")
    }
}

/// Lightweight App Group inbox used by the Share extension. The extension only
/// records URLs; the main app owns resolution, persistence and user-visible errors.
struct SharedURLInbox {
    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let urlString: String
        let receivedAt: Date
        var lastError: String?
        var attempts: Int?

        init(urlString: String, receivedAt: Date = .now, lastError: String? = nil, attempts: Int = 0) {
            self.id = UUID()
            self.urlString = urlString
            self.receivedAt = receivedAt
            self.lastError = lastError
            self.attempts = attempts
        }
    }

    private let defaults: UserDefaults
    private let key = "shared-url-inbox-v1"

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults ?? .standard
    }

    func enqueue(_ url: URL) {
        var entries = load()
        guard !entries.contains(where: { $0.urlString == url.absoluteString }) else { return }
        entries.append(Entry(urlString: url.absoluteString))
        save(entries)
    }

    func load() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    func markFailed(id: UUID, error: String) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastError = error
        entries[index].attempts = (entries[index].attempts ?? 0) + 1
        save(entries)
    }

    func save(_ entries: [Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
