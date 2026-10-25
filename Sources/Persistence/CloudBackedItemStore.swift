import Foundation

/// App-facing adapter: migrate/read/write locally, then notify the sync engine
/// after the transaction has committed. CloudKit latency never gates a write.
struct CloudBackedItemStore: AlertOutboxStoring {
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

    @discardableResult
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        let stored = try await localStore.upsert(item, observation: observation)
        Task { await syncManager.enqueueDirtyChanges() }
        return stored
    }

    @discardableResult
    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?) async throws -> Item {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        let stored = try await localStore.commitRefresh(item, expected: expected, observation: observation)
        Task { await syncManager.enqueueDirtyChanges() }
        return stored
    }

    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?, alerts: [PriceAlert]) async throws -> Item {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        let stored = try await localStore.commitRefresh(item, expected: expected, observation: observation, alerts: alerts)
        Task { await syncManager.enqueueDirtyChanges() }
        return stored
    }

    func pendingAlertDeliveries() async throws -> [PriceAlert] {
        try await localStore.pendingAlertDeliveries()
    }

    func acknowledgeAlertDelivery(id: UUID) async throws {
        try await localStore.acknowledgeAlertDelivery(id: id)
    }

    func observations(for identityKey: String) async throws -> [PriceObservation] {
        try await localStore.observations(for: identityKey)
    }

    func delete(id: UUID) async throws {
        _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
        try await localStore.delete(id: id)
        Task { await syncManager.enqueueDirtyChanges() }
    }
}
