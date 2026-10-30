import Foundation

struct RemoteSyncResult: Equatable, Sendable {
    var full: Bool
    var received: Int
    var deleted: Int
    var syncedAt: Date
}

struct RemoteRefreshResult: Sendable {
    var item: Item
    var deferred: Bool
    var why: String?
}

/// The catalog as served by PriceBucket, with a local SQLite cache so the app
/// reads without network. Reads never touch the network. Mutations write
/// through (API first, then cache) and surface the error when the network
/// fails: there are no offline writes in this version.
actor RemoteItemStore: PriceHistoryStoring {
    static let serverTimeKey = "pricebucket-server-time-v1"
    static let sourceKey = "pricebucket-source-v1"
    static let lastSyncKey = "pricebucket-last-sync-v1"

    let cache: SQLiteItemStore
    private let client: PriceBucketClient
    private let settings: PriceBucketSettings
    private let now: @Sendable () -> Date
    private var syncTask: Task<RemoteSyncResult, Error>?

    init(
        cache: SQLiteItemStore,
        client: PriceBucketClient,
        settings: PriceBucketSettings,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.client = client
        self.settings = settings
        self.now = now
    }

    nonisolated var isConfigured: Bool { settings.isConfigured }

    // MARK: Reads (cache only)

    func loadAll() async throws -> [Item] {
        try await cache.loadAll()
    }

    func observations(for identityKey: String) async throws -> [PriceObservation] {
        try await cache.observations(for: identityKey)
    }

    func lastSyncDate() async -> Date? {
        guard let data = try? await cache.metadataData(for: Self.lastSyncKey),
              let seconds = String(data: data, encoding: .utf8).flatMap(Double.init) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Sync

    /// Pull only: the server is the authority and there are no local merges.
    /// Concurrent callers share one request.
    @discardableResult
    func sync() async throws -> RemoteSyncResult {
        if let syncTask { return try await syncTask.value }
        let task = Task { try await performSync() }
        syncTask = task
        defer { syncTask = nil }
        return try await task.value
    }

    private func performSync() async throws -> RemoteSyncResult {
        let config = try settings.configuration()
        let source = config.baseURL.absoluteString
        let cachedSource = try await cache.metadataData(for: Self.sourceKey).flatMap { String(data: $0, encoding: .utf8) }
        // A different server means a different catalog: start over.
        let since = cachedSource == source
            ? try await cache.metadataData(for: Self.serverTimeKey).flatMap { String(data: $0, encoding: .utf8) }
            : nil

        let response = try await client.items(since: since)
        let syncedAt = now()
        try await cache.applyServerChanges(
            upserts: response.items,
            deletedIDs: response.deleted,
            replaceAll: response.full,
            metadata: [
                Self.serverTimeKey: Data(response.serverTime.utf8),
                Self.sourceKey: Data(source.utf8),
                Self.lastSyncKey: Data(String(syncedAt.timeIntervalSince1970).utf8),
            ]
        )
        return RemoteSyncResult(full: response.full, received: response.items.count,
                                deleted: response.deleted.count, syncedAt: syncedAt)
    }

    // MARK: Mutations (write-through)

    /// `POST /items`. Amazon and blocked pages come back pending (no price).
    @discardableResult
    func add(url: URL, size: String? = nil, color: String? = nil) async throws -> Item {
        let item = try await client.addItem(url: url, size: size, color: color)
        try await store(item)
        return item
    }

    /// Updates an existing item with PATCH, or adds the URL when it is unknown.
    /// Fields the backend does not store are ignored.
    @discardableResult
    func upsert(_ item: Item) async throws -> Item {
        let cached = try await cachedMatch(for: item)
        guard let cached else { return try await add(url: item.canonicalURL, size: item.size, color: item.color) }
        let patch = ItemPatch.diff(from: cached, to: item)
        if patch.isEmpty { return cached }
        let updated = try await client.patchItem(id: cached.id, patch: patch)
        try await store(updated)
        return updated
    }

    /// History is owned by the server, so the observation is not stored locally.
    @discardableResult
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        try await upsert(item)
    }

    @discardableResult
    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?) async throws -> Item {
        guard try await cache.item(id: expected.id) != nil else { throw RefreshCommitError.itemChanged }
        if ItemPatch.diff(from: expected, to: item).isEmpty, item != expected {
            throw PriceBucketError.unsupported("El servidor todavía no guarda este dato; el cambio no se ha aplicado.")
        }
        return try await upsert(item)
    }

    func delete(id: UUID) async throws {
        do {
            try await client.deleteItem(id: id)
        } catch PriceBucketError.notFound {
            // Already gone on the server: converge instead of failing.
        }
        try await cache.delete(id: id)
    }

    func save(_ items: [Item]) async throws {
        throw PriceBucketError.unsupported("Con el servidor no se puede reemplazar el catálogo entero desde la app.")
    }

    /// `POST /items/:id/refresh`. `deferred` means the daily routine will check it.
    func refresh(id: UUID) async throws -> RemoteRefreshResult {
        let response = try await client.refreshItem(id: id)
        try await store(response.item)
        return RemoteRefreshResult(item: response.item, deferred: response.deferred, why: response.why)
    }

    /// `GET /items/:id/history`, cached in `price_observations`. The server list
    /// replaces what was cached, since its final point moves with every check.
    func refreshHistory(for item: Item) async throws {
        let points = try await client.history(id: item.id)
        try await cache.replaceObservations(points.map { $0.observation(for: item) }, identityKey: item.identityKey)
    }

    func testConnection() async throws -> MeResponse {
        try await client.me()
    }

    // MARK: Helpers

    private func store(_ item: Item) async throws {
        try await cache.applyServerChanges(upserts: [item], deletedIDs: [], replaceAll: false, metadata: [:])
    }

    private func cachedMatch(for item: Item) async throws -> Item? {
        let all = try await cache.loadAll()
        return all.first { $0.id == item.id } ?? all.first { $0.identityKey == item.identityKey }
    }
}
