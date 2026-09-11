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

/// Compact, store-agnostic product data captured from a rendered webpage. Safari
/// can provide it to the Share extension; the main app produces the same shape
/// through WebKit when a pasted URL has incomplete server-side metadata.
struct SharedPageCapture: Codable, Hashable, Sendable {
    var pageURLString: String?
    var canonicalURLString: String?
    var title: String?
    var description: String?
    var imageURLString: String?
    var priceCents: Int?
    var currency: String?
    var category: String?

    init(
        pageURLString: String? = nil,
        canonicalURLString: String? = nil,
        title: String? = nil,
        description: String? = nil,
        imageURLString: String? = nil,
        priceCents: Int? = nil,
        currency: String? = nil,
        category: String? = nil
    ) {
        self.pageURLString = pageURLString
        self.canonicalURLString = canonicalURLString
        self.title = title
        self.description = description
        self.imageURLString = imageURLString
        self.priceCents = priceCents
        self.currency = currency
        self.category = category
    }

    init?(propertyList: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = propertyList[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        pageURLString = string("pageURL")
        canonicalURLString = string("canonicalURL")
        title = string("title")
        description = string("description")
        imageURLString = string("imageURL")
        priceCents = (propertyList["priceCents"] as? NSNumber)?.intValue
        currency = string("currency")?.uppercased()
        category = string("category")

        guard pageURLString != nil || canonicalURLString != nil || title != nil else { return nil }
    }

    var pageURL: URL? {
        pageURLString.flatMap(URL.init(string:))
    }

    var canonicalURL: URL? {
        canonicalURLString.flatMap(URL.init(string:))
    }

    var imageURL: URL? {
        imageURLString.flatMap(URL.init(string:))
    }
}

/// Lightweight App Group inbox used by the Share extension. The extension only
/// records URLs and optional rendered metadata; the main app owns resolution,
/// persistence and user-visible errors.
struct SharedURLInbox {
    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let urlString: String
        let receivedAt: Date
        var lastError: String?
        var attempts: Int?
        var pageCapture: SharedPageCapture?

        init(
            urlString: String,
            receivedAt: Date = .now,
            lastError: String? = nil,
            attempts: Int = 0,
            pageCapture: SharedPageCapture? = nil
        ) {
            self.id = UUID()
            self.urlString = urlString
            self.receivedAt = receivedAt
            self.lastError = lastError
            self.attempts = attempts
            self.pageCapture = pageCapture
        }
    }

    private let defaults: UserDefaults
    private let key = "shared-url-inbox-v1"

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.identifier)) {
        self.defaults = defaults ?? .standard
    }

    func enqueue(_ url: URL, pageCapture: SharedPageCapture? = nil) {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.urlString == url.absoluteString }) {
            guard let pageCapture else { return }
            entries[index].pageCapture = pageCapture
            entries[index].lastError = nil
            entries[index].attempts = 0
        } else {
            entries.append(Entry(urlString: url.absoluteString, pageCapture: pageCapture))
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
