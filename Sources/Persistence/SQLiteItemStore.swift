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
actor SQLiteItemStore {
    static let migrationMetadataKey = "items-json-migration-v1"
    static let syncStateMetadataKey = "ck-sync-engine-state-v1"
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
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let recordName = CloudRecordIdentity.recordName(for: item.identityKey)
            var value = item
            if let existing = try localRecord(named: recordName)?.item {
                value.id = existing.id
                value.createdAt = existing.createdAt
            }
            try write([value], deleteMissing: false)
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func delete(id: UUID) throws {
        let statement = try prepare(
            "UPDATE item_records SET tombstone = 1, dirty = 1 WHERE item_id = ? AND tombstone = 0"
        )
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
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
        let payload = try item.map { try encoder.encode($0) }
        let itemID = item?.id.uuidString ?? recordName
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

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
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
