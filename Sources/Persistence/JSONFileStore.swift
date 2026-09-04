import Foundation

/// Generic atomic JSON-array-in-a-file store. Backs both items and alerts —
/// see `JSONFileItemStore` / `JSONFileAlertStore` below. An `actor` because
/// several refreshes can run concurrently (see Refresh/RefreshCoordinator.swift)
/// and reads/writes must not interleave.
actor JSONFileStore<Element: Codable & Sendable> {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        // `.secondsSince1970` round-trips a `Date`'s underlying Double exactly
        // (it's just a JSON number) — unlike any string format, which truncates
        // to some fixed number of fractional digits and silently breaks `==`
        // between an in-memory `Item` and the one just loaded back from disk.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func loadAll() throws -> [Element] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try decoder.decode([Element].self, from: data)
    }

    func save(_ elements: [Element]) throws {
        let data = try encoder.encode(elements)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Write to a sibling temp file then rename: a crash mid-write must never
        // leave `items.json` truncated (same lesson as RemoteSSH's state files).
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}

struct JSONFileItemStore: ItemStoring {
    private let backing: JSONFileStore<Item>

    init(fileURL: URL) {
        backing = JSONFileStore(fileURL: fileURL)
    }

    func loadAll() async throws -> [Item] {
        try await backing.loadAll()
    }

    func save(_ items: [Item]) async throws {
        try await backing.save(items)
    }
}

struct JSONFileAlertStore: AlertStoring {
    private let backing: JSONFileStore<PriceAlert>

    init(fileURL: URL) {
        backing = JSONFileStore(fileURL: fileURL)
    }

    func loadAll() async throws -> [PriceAlert] {
        try await backing.loadAll()
    }

    func save(_ alerts: [PriceAlert]) async throws {
        try await backing.save(alerts)
    }
}
