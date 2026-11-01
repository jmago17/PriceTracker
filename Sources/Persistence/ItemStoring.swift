import Foundation

/// Minimal, testable persistence contract. Row-level mutations are requirements
/// so the SQLite store can update atomically across app/App Intent processes;
/// the defaults retain the simple whole-array behavior for in-memory fakes.
protocol ItemStoring: Sendable {
    func loadAll() async throws -> [Item]
    func save(_ items: [Item]) async throws
    @discardableResult func upsert(_ item: Item) async throws -> Item
    func delete(id: UUID) async throws
}

/// Items plus their price history. In production the history is owned by the
/// server and cached locally.
protocol PriceHistoryStoring: ItemStoring {
    @discardableResult func upsert(_ item: Item, observation: PriceObservation) async throws -> Item
    func observations(for identityKey: String) async throws -> [PriceObservation]
    /// Compare and commit in one transaction; never resurrect a deleted item or
    /// overwrite an edit made after the coordinator's last read.
    @discardableResult func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?) async throws -> Item
}

extension PriceHistoryStoring {
    /// Fallback for lightweight in-memory test stores. SQLite overrides atomically.
    @discardableResult
    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?) async throws -> Item {
        guard try await self.item(id: expected.id) == expected else { throw RefreshCommitError.itemChanged }
        if let observation { return try await upsert(item, observation: observation) }
        return try await upsert(item)
    }
}

enum RefreshCommitError: Error, LocalizedError {
    case itemChanged
    var errorDescription: String? {
        "El artículo se modificó o eliminó durante la comprobación. Vuelve a intentarlo."
    }
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
