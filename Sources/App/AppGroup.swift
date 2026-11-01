import Foundation

enum AppGroup {
    static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo-catalog") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    static let identifier = "group.com.maromeapps.PriceTracker"

    /// Root shared container. Crashes if the App Group entitlement is missing or
    /// misconfigured — that is a build/signing bug, not a runtime condition to recover from.
    static var containerURL: URL {
        if isDemo {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PriceTrackerDemo", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group container '\(identifier)' is unavailable — check the entitlement.")
        }
        return url
    }

    static var databaseURL: URL {
        containerURL.appendingPathComponent("catalog.sqlite")
    }

    /// Read cache of the PriceBucket catalog. Deliberately NOT `catalog.sqlite`:
    /// that file holds the pre-server data and a server reconciliation must not
    /// tombstone rows from it. `catalog.sqlite` is only the demo/XCTest store.
    static var remoteCacheURL: URL {
        containerURL.appendingPathComponent("remote-cache.sqlite")
    }
}

/// Lightweight App Group inbox. The Share extension sends links straight to the
/// server and only parks them here when it cannot (no key, no network); the main
/// app drains the inbox to the server the next time it becomes active.
struct SharedURLInbox: Sendable {
    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let urlString: String
        let receivedAt: Date
        var lastError: String?
        var attempts: Int?
        /// Optional values typed in the Share sheet, applied when the link is sent.
        var size: String?
        var targetPriceCents: Int?

        init(
            urlString: String,
            receivedAt: Date = .now,
            lastError: String? = nil,
            attempts: Int = 0,
            size: String? = nil,
            targetPriceCents: Int? = nil
        ) {
            self.id = UUID()
            self.urlString = urlString
            self.receivedAt = receivedAt
            self.lastError = lastError
            self.attempts = attempts
            self.size = size
            self.targetPriceCents = targetPriceCents
        }
    }

    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key = "shared-url-inbox-v1"

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults ?? .standard
    }

    func enqueue(_ url: URL, size: String? = nil, targetPriceCents: Int? = nil) {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.urlString == url.absoluteString }) {
            // Same link shared again: keep one entry, taking the newest values.
            if let size { entries[index].size = size }
            if let targetPriceCents { entries[index].targetPriceCents = targetPriceCents }
        } else {
            entries.append(Entry(urlString: url.absoluteString, size: size, targetPriceCents: targetPriceCents))
        }
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
