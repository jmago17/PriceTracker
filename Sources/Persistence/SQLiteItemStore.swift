import Foundation
import SQLite3

struct LocalItemRecord: Sendable {
    var recordName: String
    var identityKey: String
    var item: Item?
    var isTombstone: Bool
    var isDirty: Bool
    var systemFields: Data?
}

enum LegacyCatalogMigrationResult: Equatable, Sendable {
    case alreadyCompleted
    case noLegacyCatalog
    case migrated(Int)
}

enum SQLiteStoreError: Error, LocalizedError {
    case open(String)
    case execute(String)
    case corruptRow(String)
    case migrationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .open(let message): return "No se pudo abrir el catálogo local: \(message)"
        case .execute(let message): return "Error en el catálogo local: \(message)"
        case .corruptRow(let recordName): return "El registro local \(recordName) está dañado."
        case .migrationVerificationFailed: return "La migración del catálogo JSON no se pudo verificar."
        }
    }
}

/// Record-oriented local source of truth. Every app-facing write commits here
/// before CloudKit is notified, so reads and writes remain available offline.
/// WAL plus SQLite's process locks make separate app/App Intent processes safe.
actor SQLiteItemStore: AlertOutboxStoring {
    static let migrationMetadataKey = "items-json-migration-v1"
    // New record types require a full bootstrap. A separate key also prevents
    // downgraded clients from advancing past history records they ignore.
    static let syncStateMetadataKey = "ck-sync-engine-state-history-v2"
    static let accountMetadataKey = "ck-account-record-name-v1"
    static let lastSuccessfulSyncMetadataKey = "ck-last-successful-sync-v1"

    private let databaseURL: URL
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func loadAll() throws -> [Item] {
        let statement = try prepare(
            "SELECT record_name, payload FROM item_records WHERE tombstone = 0 ORDER BY identity_key"
        )
        defer { sqlite3_finalize(statement) }

        var items: [Item] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordName = columnString(statement, index: 0) ?? "unknown"
            guard let data = columnData(statement, index: 1),
                  let item = try? decoder.decode(Item.self, from: data) else {
                throw SQLiteStoreError.corruptRow(recordName)
            }
            items.append(item)
        }
        try checkStatement(statement)
        return items
    }

    /// Reconciles the complete active catalog. Missing rows become tombstones;
    /// unchanged rows are left clean and are not uploaded again.
    func save(_ items: [Item]) throws {
        _ = try connection()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try write(items, deleteMissing: true)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func upsert(_ item: Item) throws -> Item {
        try upsert(item, observation: nil)
    }

    @discardableResult
    func upsert(_ item: Item, observation: PriceObservation) throws -> Item {
        try upsert(item, observation: Optional(observation))
    }

    @discardableResult
    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?) throws -> Item {
        try upsert(item, observation: observation, expected: expected)
    }

    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?, alerts: [PriceAlert]) throws -> Item {
        try upsert(item, observation: observation, expected: expected, alerts: alerts)
    }

    func pendingAlertDeliveries() throws -> [PriceAlert] {
        let statement = try prepare("SELECT o.payload FROM alert_outbox o JOIN item_records i ON i.identity_key = o.identity_key WHERE i.tombstone = 0 AND i.item_id = o.item_id ORDER BY o.rowid")
        defer { sqlite3_finalize(statement) }
        var values: [PriceAlert] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = columnData(statement, index: 0) else { throw SQLiteStoreError.corruptRow("alert_outbox") }
            values.append(try decoder.decode(PriceAlert.self, from: data))
        }
        try checkStatement(statement)
        return values
    }

    func acknowledgeAlertDelivery(id: UUID) throws {
        let statement = try prepare("DELETE FROM alert_outbox WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    private func upsert(_ item: Item, observation: PriceObservation?, expected: Item? = nil, alerts: [PriceAlert] = []) throws -> Item {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let recordName = CloudRecordIdentity.recordName(for: item.identityKey)
            let record = try localRecord(named: recordName)
            if let expected {
                guard record?.isTombstone == false, record?.item == expected else {
                    throw RefreshCommitError.itemChanged
                }
            }
            var value = item
            if let existing = record?.item {
                value.id = existing.id
                value.createdAt = existing.createdAt
            }
            try write([value], deleteMissing: false)
            if var observation {
                observation.itemID = value.id
                let statement = try prepare("INSERT OR IGNORE INTO price_observations (id, identity_key, checked_at, payload) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(observation.id.uuidString, to: 1, in: statement)
                bind(value.identityKey, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, observation.checkedAt.timeIntervalSince1970)
                bind(try encoder.encode(observation), to: 4, in: statement)
                try stepDone(statement)
            }
            for alert in alerts {
                guard alert.itemID == value.id else { throw RefreshCommitError.itemChanged }
                let statement = try prepare("INSERT INTO alert_outbox (id, identity_key, item_id, payload) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(alert.id.uuidString, to: 1, in: statement)
                bind(value.identityKey, to: 2, in: statement)
                bind(value.id.uuidString, to: 3, in: statement)
                bind(try encoder.encode(alert), to: 4, in: statement)
                try stepDone(statement)
            }
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func observations(for identityKey: String) throws -> [PriceObservation] {
        let item = try localRecord(named: CloudRecordIdentity.recordName(for: identityKey))
        if item?.isTombstone == true { return [] }
        let statement = try prepare("SELECT p.payload FROM price_observations p LEFT JOIN observation_sync s ON s.observation_id = p.id WHERE p.identity_key = ? AND COALESCE(s.tombstone, 0) = 0 ORDER BY p.checked_at, p.id")
        defer { sqlite3_finalize(statement) }
        bind(identityKey, to: 1, in: statement)
        var result: [PriceObservation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = columnData(statement, index: 0) else { throw SQLiteStoreError.corruptRow(identityKey) }
            var observation = try decoder.decode(PriceObservation.self, from: data)
            if let id = item?.item?.id { observation.itemID = id }
            result.append(observation)
        }
        try checkStatement(statement)
        return result
    }

    /// Incremental migration also discovers observations written by an older
    /// app/Shortcut process after this version first opened the database.
    func prepareObservationSync() throws {
        // Bound memory and group durable writes; old writers remain discoverable.
        while true {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let query = try prepare("SELECT p.id, p.identity_key FROM price_observations p LEFT JOIN observation_sync s ON s.observation_id = p.id WHERE s.observation_id IS NULL LIMIT 500")
                var missing: [(String, String)] = []
                while sqlite3_step(query) == SQLITE_ROW {
                    guard let id = columnString(query, index: 0), let key = columnString(query, index: 1) else {
                        sqlite3_finalize(query)
                        throw SQLiteStoreError.corruptRow("history migration")
                    }
                    missing.append((id, key))
                }
                defer { sqlite3_finalize(query) }
                try checkStatement(query)
                let insert = try prepare("INSERT INTO observation_sync (record_name, observation_id, identity_key) VALUES (?, ?, ?) ON CONFLICT(record_name) DO UPDATE SET observation_id = COALESCE(observation_sync.observation_id, excluded.observation_id), identity_key = COALESCE(observation_sync.identity_key, excluded.identity_key)")
                defer { sqlite3_finalize(insert) }
                for (id, key) in missing {
                    guard let uuid = UUID(uuidString: id) else { throw SQLiteStoreError.corruptRow(id) }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    bind(CloudObservationCodec.recordName(identityKey: key, id: uuid), to: 1, in: insert)
                    bind(id, to: 2, in: insert); bind(key, to: 3, in: insert)
                    try stepDone(insert)
                }
                try execute("COMMIT")
                if missing.count < 500 { return }
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    func dirtyObservationNames() throws -> [String] {
        try prepareObservationSync()
        let query = try prepare("SELECT record_name FROM observation_sync WHERE dirty = 1")
        defer { sqlite3_finalize(query) }
        var result: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            if let name = columnString(query, index: 0) { result.append(name) }
        }
        try checkStatement(query)
        return result
    }

    func dirtyObservationCount() throws -> Int {
        let query = try prepare("SELECT COUNT(*) FROM observation_sync WHERE dirty = 1")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { try checkStatement(query); return 0 }
        return Int(sqlite3_column_int64(query, 0))
    }

    func observationRecords(dirtyOnly: Bool = false, named: String? = nil) throws -> [LocalObservationRecord] {
        if named == nil { try prepareObservationSync() }
        let condition = named != nil ? "s.record_name = ?" : (dirtyOnly ? "s.dirty = 1" : "1 = 1")
        let statement = try prepare("SELECT s.record_name, s.identity_key, p.payload, s.tombstone, s.dirty, s.system_fields FROM observation_sync s LEFT JOIN price_observations p ON p.id = s.observation_id WHERE " + condition)
        defer { sqlite3_finalize(statement) }
        if let named { bind(named, to: 1, in: statement) }
        var result: [LocalObservationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let observation = try columnData(statement, index: 2).map { try decoder.decode(PriceObservation.self, from: $0) }
            guard let name = columnString(statement, index: 0) else { throw SQLiteStoreError.corruptRow("observation name") }
            result.append(LocalObservationRecord(recordName: name,
                identityKey: columnString(statement, index: 1), observation: observation,
                isTombstone: sqlite3_column_int(statement, 3) != 0,
                isDirty: sqlite3_column_int(statement, 4) != 0, systemFields: columnData(statement, index: 5)))
        }
        try checkStatement(statement)
        return result
    }

    /// Union by immutable UUID. Repeated downloads are no-ops; disagreement
    /// about one UUID is surfaced, never resolved by discarding a real sample.
    func applyRemoteObservation(_ remote: LocalObservationRecord) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let local = try observationRecords(named: remote.recordName).first
            if let a = local?.observation, let b = remote.observation,
               !CloudObservationCodec.sameSample(a, b) {
                throw SQLiteStoreError.corruptRow("Conflicto en observación \(a.id)")
            }
            let tombstone = remote.isTombstone || local?.isTombstone == true
            if let observation = remote.observation, let key = remote.identityKey {
                let existing = try prepare("SELECT identity_key, payload FROM price_observations WHERE id = ?")
                defer { sqlite3_finalize(existing) }
                bind(observation.id.uuidString, to: 1, in: existing)
                if sqlite3_step(existing) == SQLITE_ROW {
                    guard columnString(existing, index: 0) == key,
                          let data = columnData(existing, index: 1),
                          CloudObservationCodec.sameSample(try decoder.decode(PriceObservation.self, from: data), observation) else {
                        throw SQLiteStoreError.corruptRow("Observation UUID collision")
                    }
                } else {
                    try checkStatement(existing)
                }
                let insert = try prepare("INSERT OR IGNORE INTO price_observations (id, identity_key, checked_at, payload) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(insert) }
                bind(observation.id.uuidString, to: 1, in: insert); bind(key, to: 2, in: insert)
                sqlite3_bind_double(insert, 3, observation.checkedAt.timeIntervalSince1970)
                bind(try encoder.encode(observation), to: 4, in: insert)
                try stepDone(insert)
            }
            let statement = try prepare("INSERT INTO observation_sync (record_name, observation_id, identity_key, tombstone, dirty, system_fields) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(record_name) DO UPDATE SET observation_id = COALESCE(observation_sync.observation_id, excluded.observation_id), identity_key = COALESCE(observation_sync.identity_key, excluded.identity_key), tombstone = excluded.tombstone, dirty = excluded.dirty, system_fields = excluded.system_fields")
            defer { sqlite3_finalize(statement) }
            bind(remote.recordName, to: 1, in: statement)
            bind((remote.observation ?? local?.observation)?.id.uuidString, to: 2, in: statement)
            bind(remote.identityKey ?? local?.identityKey, to: 3, in: statement)
            sqlite3_bind_int(statement, 4, tombstone ? 1 : 0)
            sqlite3_bind_int(statement, 5, tombstone && !remote.isTombstone ? 1 : 0)
            bind(remote.systemFields, to: 6, in: statement)
            try stepDone(statement)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func retainIncomingRecord(named name: String, archive: Data) throws {
        let query = try prepare("INSERT INTO incoming_sync_records (record_name, archive) VALUES (?, ?) ON CONFLICT(record_name) DO UPDATE SET archive = excluded.archive")
        defer { sqlite3_finalize(query) }
        bind(name, to: 1, in: query); bind(archive, to: 2, in: query)
        try stepDone(query)
    }

    func retainedIncomingRecords() throws -> [Data] {
        let query = try prepare("SELECT archive FROM incoming_sync_records")
        defer { sqlite3_finalize(query) }
        var result: [Data] = []
        while sqlite3_step(query) == SQLITE_ROW {
            if let archive = columnData(query, index: 0) { result.append(archive) }
        }
        try checkStatement(query)
        return result
    }

    func removeRetainedIncomingRecord(named name: String) throws {
        let query = try prepare("DELETE FROM incoming_sync_records WHERE record_name = ?")
        defer { sqlite3_finalize(query) }
        bind(name, to: 1, in: query); try stepDone(query)
    }

    func resetObservationSystemFields(named name: String) throws {
        let statement = try prepare("UPDATE observation_sync SET system_fields = NULL, dirty = 1 WHERE record_name = ?")
        defer { sqlite3_finalize(statement) }
        bind(name, to: 1, in: statement); try stepDone(statement)
    }

    func tombstoneObservation(named name: String) throws {
        let statement = try prepare("INSERT INTO observation_sync (record_name, tombstone, dirty) VALUES (?, 1, 1) ON CONFLICT(record_name) DO UPDATE SET tombstone = 1, dirty = 1, system_fields = NULL")
        defer { sqlite3_finalize(statement) }
        bind(name, to: 1, in: statement); try stepDone(statement)
    }

    func delete(id: UUID) throws {
        let statement = try prepare(
            "UPDATE item_records SET tombstone = 1, dirty = 1 WHERE item_id = ? AND tombstone = 0"
        )
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    /// Remote-cache write: the server is the authority, so rows are written with
    /// the server's ids (unlike `upsert`, which keeps a local id for a known
    /// identity). Deletions apply first, `replaceAll` tombstones whatever the
    /// server did not send, and `metadata` commits in the same transaction.
    func applyServerChanges(
        upserts: [Item],
        deletedIDs: [UUID],
        replaceAll: Bool,
        metadata: [String: Data]
    ) throws {
        _ = try connection()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for id in deletedIDs {
                let statement = try prepare(
                    "UPDATE item_records SET tombstone = 1, dirty = 1 WHERE item_id = ? AND tombstone = 0"
                )
                defer { sqlite3_finalize(statement) }
                bind(id.uuidString, to: 1, in: statement)
                try stepDone(statement)
            }
            try write(upserts, deleteMissing: replaceAll)
            for (key, value) in metadata { try setMetadataData(value, for: key) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Replaces the cached history of one item with the server's list.
    func replaceObservations(_ observations: [PriceObservation], identityKey: String) throws {
        _ = try connection()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let clear = try prepare("DELETE FROM price_observations WHERE identity_key = ?")
            defer { sqlite3_finalize(clear) }
            bind(identityKey, to: 1, in: clear)
            try stepDone(clear)
            let clearSync = try prepare("DELETE FROM observation_sync WHERE identity_key = ?")
            defer { sqlite3_finalize(clearSync) }
            bind(identityKey, to: 1, in: clearSync)
            try stepDone(clearSync)
            for observation in observations {
                let statement = try prepare("INSERT OR REPLACE INTO price_observations (id, identity_key, checked_at, payload) VALUES (?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(observation.id.uuidString, to: 1, in: statement)
                bind(identityKey, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, observation.checkedAt.timeIntervalSince1970)
                bind(try encoder.encode(observation), to: 4, in: statement)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Idempotent migration from the former JSON source of truth. The original
    /// file is deliberately retained as a recovery copy. The completion marker
    /// is written only after every identity can be read back from SQLite.
    func migrateLegacyJSONIfNeeded(from legacyURL: URL) throws -> LegacyCatalogMigrationResult {
        if try metadataData(for: Self.migrationMetadataKey) != nil {
            return .alreadyCompleted
        }

        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            try setMetadataData(Data("no-legacy-catalog".utf8), for: Self.migrationMetadataKey)
            return .noLegacyCatalog
        }

        let data = try Data(contentsOf: legacyURL)
        let items = data.isEmpty ? [] : try decoder.decode([Item].self, from: data)
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try write(items, deleteMissing: false)
            let expectedIdentities = Set(items.map(\.identityKey))
            let storedIdentities = try activeIdentityKeys()
            guard expectedIdentities.isSubset(of: storedIdentities) else {
                throw SQLiteStoreError.migrationVerificationFailed
            }
            try setMetadataData(Data("completed".utf8), for: Self.migrationMetadataKey)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return .migrated(Set(items.map(\.identityKey)).count)
    }

    func localRecord(named recordName: String) throws -> LocalItemRecord? {
        let statement = try prepare(
            "SELECT identity_key, payload, tombstone, dirty, system_fields FROM item_records WHERE record_name = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(recordName, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkStatement(statement)
            return nil
        }
        return try decodeLocalRecord(statement, recordName: recordName)
    }

    func dirtyRecords() throws -> [LocalItemRecord] {
        let statement = try prepare(
            "SELECT record_name, identity_key, payload, tombstone, dirty, system_fields FROM item_records WHERE dirty = 1"
        )
        defer { sqlite3_finalize(statement) }
        var records: [LocalItemRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordName = columnString(statement, index: 0) ?? "unknown"
            records.append(try decodeLocalRecord(statement, recordName: recordName, offset: 1))
        }
        try checkStatement(statement)
        return records
    }

    func dirtyCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM item_records WHERE dirty = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkStatement(statement)
            return 0
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Applies a server record while retaining its system fields as the next
    /// three-way-merge ancestor. `dirty` remains true when local edits must be
    /// sent back after the merge.
    func applyRemote(
        recordName: String,
        identityKey: String,
        item: Item?,
        isTombstone: Bool,
        systemFields: Data,
        dirty: Bool
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            // Device-local identity must survive remote updates, including callers
            // that did not pass through CloudRecordCodec's device-field merge.
            var value = item
            if let localID = try localRecord(named: recordName)?.item?.id {
                value?.id = localID
            }
            let payload = try value.map { try encoder.encode($0) }
            let itemID = value?.id.uuidString ?? recordName
            let statement = try prepare(
                """
                INSERT INTO item_records
                    (record_name, identity_key, item_id, payload, tombstone, dirty, system_fields)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(record_name) DO UPDATE SET
                    identity_key = excluded.identity_key,
                    item_id = CASE WHEN excluded.payload IS NULL THEN item_records.item_id ELSE excluded.item_id END,
                    payload = COALESCE(excluded.payload, item_records.payload),
                    tombstone = excluded.tombstone,
                    dirty = excluded.dirty,
                    system_fields = excluded.system_fields
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(recordName, to: 1, in: statement)
            bind(identityKey, to: 2, in: statement)
            bind(itemID, to: 3, in: statement)
            bind(payload, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, isTombstone ? 1 : 0)
            sqlite3_bind_int(statement, 6, dirty ? 1 : 0)
            bind(systemFields, to: 7, in: statement)
            try stepDone(statement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Records the server's new changeTag. A newer local edit keeps the row
    /// dirty and will be sent in a subsequent batch.
    func acknowledgeSavedRecord(
        named recordName: String,
        systemFields: Data,
        matchesCurrentLocalValue: Bool
    ) throws -> Bool {
        let statement = try prepare(
            "UPDATE item_records SET system_fields = ?, dirty = CASE WHEN ? = 1 THEN 0 ELSE dirty END WHERE record_name = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(systemFields, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, matchesCurrentLocalValue ? 1 : 0)
        bind(recordName, to: 3, in: statement)
        try stepDone(statement)
        return try localRecord(named: recordName)?.isDirty ?? false
    }

    /// Discards a server version that no longer exists while preserving the
    /// local payload, tombstone and pending state. The next encoded CKRecord is
    /// therefore a creation without a stale recordChangeTag.
    func clearSystemFields(named recordName: String) throws {
        let statement = try prepare(
            "UPDATE item_records SET system_fields = NULL WHERE record_name = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(recordName, to: 1, in: statement)
        try stepDone(statement)
    }

    /// A physical server deletion is unexpected because this app uploads
    /// tombstones. If the row is known, recreate it as a tombstone so an old
    /// device cannot later resurrect it.
    func turnPhysicalServerDeletionIntoTombstone(recordName: String) throws -> Bool {
        let statement = try prepare(
            "UPDATE item_records SET tombstone = 1, dirty = 1 WHERE record_name = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(recordName, to: 1, in: statement)
        try stepDone(statement)
        return sqlite3_changes(try connection()) > 0
    }

    func metadataData(for key: String) throws -> Data? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            try checkStatement(statement)
            return nil
        }
        return columnData(statement, index: 0)
    }

    func setMetadataData(_ data: Data?, for key: String) throws {
        if let data {
            let statement = try prepare(
                "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
            )
            defer { sqlite3_finalize(statement) }
            bind(key, to: 1, in: statement)
            bind(data, to: 2, in: statement)
            try stepDone(statement)
        } else {
            let statement = try prepare("DELETE FROM metadata WHERE key = ?")
            defer { sqlite3_finalize(statement) }
            bind(key, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    private func write(_ items: [Item], deleteMissing: Bool) throws {
        let incoming = Dictionary(items.map { ($0.identityKey, $0) }, uniquingKeysWith: { _, newest in newest })
        for (identityKey, item) in incoming {
            let recordName = CloudRecordIdentity.recordName(for: identityKey)
            let payload = try encoder.encode(item)
            let existing = try localRecord(named: recordName)
            let changed = existing?.item != item || existing?.isTombstone == true
            let statement = try prepare(
                """
                INSERT INTO item_records
                    (record_name, identity_key, item_id, payload, tombstone, dirty)
                VALUES (?, ?, ?, ?, 0, 1)
                ON CONFLICT(record_name) DO UPDATE SET
                    identity_key = excluded.identity_key,
                    item_id = excluded.item_id,
                    payload = excluded.payload,
                    tombstone = 0,
                    dirty = CASE WHEN ? = 1 THEN 1 ELSE item_records.dirty END
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(recordName, to: 1, in: statement)
            bind(identityKey, to: 2, in: statement)
            bind(item.id.uuidString, to: 3, in: statement)
            bind(payload, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, changed ? 1 : 0)
            try stepDone(statement)
        }

        guard deleteMissing else { return }
        let active = try activeRecordNames()
        let incomingRecordNames = Set(incoming.keys.map(CloudRecordIdentity.recordName(for:)))
        for recordName in active.subtracting(incomingRecordNames) {
            let statement = try prepare(
                "UPDATE item_records SET tombstone = 1, dirty = 1 WHERE record_name = ? AND tombstone = 0"
            )
            defer { sqlite3_finalize(statement) }
            bind(recordName, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    private func activeIdentityKeys() throws -> Set<String> {
        try stringSet(query: "SELECT identity_key FROM item_records WHERE tombstone = 0")
    }

    private func activeRecordNames() throws -> Set<String> {
        try stringSet(query: "SELECT record_name FROM item_records WHERE tombstone = 0")
    }

    private func stringSet(query: String) throws -> Set<String> {
        let statement = try prepare(query)
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = columnString(statement, index: 0) { values.insert(value) }
        }
        try checkStatement(statement)
        return values
    }

    private func decodeLocalRecord(
        _ statement: OpaquePointer,
        recordName: String,
        offset: Int32 = 0
    ) throws -> LocalItemRecord {
        guard let identityKey = columnString(statement, index: offset) else {
            throw SQLiteStoreError.corruptRow(recordName)
        }
        let payload = columnData(statement, index: offset + 1)
        let item = try payload.map { try decoder.decode(Item.self, from: $0) }
        return LocalItemRecord(
            recordName: recordName,
            identityKey: identityKey,
            item: item,
            isTombstone: sqlite3_column_int(statement, offset + 2) != 0,
            isDirty: sqlite3_column_int(statement, offset + 3) != 0,
            systemFields: columnData(statement, index: offset + 4)
        )
    }

    private func connection() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "código \(result)"
            if let opened { sqlite3_close(opened) }
            throw SQLiteStoreError.open(message)
        }
        database = opened
        sqlite3_busy_timeout(opened, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS item_records (
                record_name TEXT PRIMARY KEY NOT NULL,
                identity_key TEXT UNIQUE NOT NULL,
                item_id TEXT NOT NULL,
                payload BLOB,
                tombstone INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1,
                system_fields BLOB
            );
            CREATE INDEX IF NOT EXISTS item_records_item_id ON item_records(item_id);
            CREATE TABLE IF NOT EXISTS price_observations (
                id TEXT PRIMARY KEY NOT NULL,
                identity_key TEXT NOT NULL,
                checked_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS price_observations_identity_time ON price_observations(identity_key, checked_at);
            CREATE TABLE IF NOT EXISTS incoming_sync_records (
                record_name TEXT PRIMARY KEY NOT NULL,
                archive BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS observation_sync (
                record_name TEXT PRIMARY KEY NOT NULL,
                observation_id TEXT UNIQUE,
                identity_key TEXT,
                tombstone INTEGER NOT NULL DEFAULT 0,
                dirty INTEGER NOT NULL DEFAULT 1,
                system_fields BLOB
            );
            CREATE TABLE IF NOT EXISTS alert_outbox (
                id TEXT PRIMARY KEY NOT NULL,
                identity_key TEXT NOT NULL,
                item_id TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
            """
        )
        applyBackgroundFileProtection()
        return opened
    }

    private func execute(_ sql: String) throws {
        let database = try connection()
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.execute(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteStoreError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(String(cString: sqlite3_errmsg(try connection())))
        }
    }

    private func checkStatement(_ statement: OpaquePointer) throws {
        let result = sqlite3_errcode(try connection())
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw SQLiteStoreError.execute(String(cString: sqlite3_errmsg(try connection())))
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private func columnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func applyBackgroundFileProtection() {
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
    }
}
