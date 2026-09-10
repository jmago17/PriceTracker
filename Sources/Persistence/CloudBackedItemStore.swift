import Foundation

/// App-facing adapter: migrate/read/write locally, then notify the sync engine
/// after the transaction has committed. CloudKit latency never gates a write.
struct CloudBackedItemStore: ItemStoring {
    let localStore: SQLiteItemStore
    let syncManager: CloudSyncManager
    let legacyJSONURL: URL

    func loadAll() async throws -> [Item] {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        let items = try await localStore.loadAll()
        Task { await syncManager.start() }
        return items
    }

    func save(_ items: [Item]) async throws {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        try await localStore.save(items)
        Task { await syncManager.enqueueDirtyChanges() }
    }

    @discardableResult
    func upsert(_ item: Item) async throws -> Item {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        let stored = try await localStore.upsert(item)
        Task { await syncManager.enqueueDirtyChanges() }
        return stored
    }

    func delete(id: UUID) async throws {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        try await localStore.delete(id: id)
        Task { await syncManager.enqueueDirtyChanges() }
    }
}
