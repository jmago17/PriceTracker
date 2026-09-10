import Foundation

/// Minimal, testable persistence contract. Row-level mutations are requirements
/// so the production SQLite store can update atomically across app/App Intent
/// processes; the defaults retain the simple whole-array behavior for fakes and
/// the legacy JSON store used by migration tests.
protocol ItemStoring: Sendable {
    func loadAll() async throws -> [Item]
    func save(_ items: [Item]) async throws
    @discardableResult func upsert(_ item: Item) async throws -> Item
    func delete(id: UUID) async throws
}

extension ItemStoring {
    func item(id: UUID) async throws -> Item? {
        try await loadAll().first { $0.id == id }
    }

    /// Insert or replace by id. If no item with this id exists but one with the
    /// same identity key does (same store/store_item_id/region), replaces that one
    /// instead — the "adding the same URL twice is a no-op" rule from the architecture.
    @discardableResult
    func upsert(_ item: Item) async throws -> Item {
        var items = try await loadAll()
        let stored: Item
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
            stored = item
        } else if let index = items.firstIndex(where: { $0.identityKey == item.identityKey }) {
            var merged = item
            merged.id = items[index].id
            merged.createdAt = items[index].createdAt
            items[index] = merged
            stored = merged
        } else {
            items.append(item)
            stored = item
        }
        try await save(items)
        return stored
    }

    func delete(id: UUID) async throws {
        var items = try await loadAll()
        items.removeAll { $0.id == id }
        try await save(items)
    }
}

protocol AlertStoring: Sendable {
    func loadAll() async throws -> [PriceAlert]
    func save(_ alerts: [PriceAlert]) async throws
}

extension AlertStoring {
    @discardableResult
    func append(_ alert: PriceAlert) async throws -> PriceAlert {
        var alerts = try await loadAll()
        alerts.append(alert)
        try await save(alerts)
        return alert
    }

    func pendingAlerts() async throws -> [PriceAlert] {
        try await loadAll().filter { $0.sentAt == nil }
    }

    func markSent(ids: Set<UUID>, at date: Date = Date()) async throws {
        var alerts = try await loadAll()
        for index in alerts.indices where ids.contains(alerts[index].id) {
            alerts[index].sentAt = date
        }
        try await save(alerts)
    }
}
