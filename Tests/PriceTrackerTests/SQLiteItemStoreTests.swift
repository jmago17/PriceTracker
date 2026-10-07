import CloudKit
import Foundation
import Testing
@testable import PriceTracker

private func makeSQLiteStore() -> (SQLiteItemStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PriceTrackerSQLiteTests")
        .appendingPathComponent(UUID().uuidString)
    return (SQLiteItemStore(databaseURL: directory.appendingPathComponent("catalog.sqlite")), directory)
}

private func sqliteItem(storeItemID: String, title: String) -> Item {
    Item(
        store: .appStore,
        storeItemID: storeItemID,
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id\(storeItemID)")!,
        title: title
    )
}

struct SQLiteItemStoreTests {
    @Test func rowUpsertsDoNotReplaceUnrelatedItems() async throws {
        let (store, _) = makeSQLiteStore()
        let first = sqliteItem(storeItemID: "1", title: "First")
        let second = sqliteItem(storeItemID: "2", title: "Second")
        try await store.upsert(first)
        try await store.upsert(second)

        var edited = first
        edited.title = "First edited"
        try await store.upsert(edited)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.storeItemID == "1" })?.title == "First edited")
        #expect(loaded.contains(where: { $0.storeItemID == "2" }))
    }

    @Test func duplicateIdentityKeepsOriginalLocalID() async throws {
        let (store, _) = makeSQLiteStore()
        let original = sqliteItem(storeItemID: "1", title: "Original")
        try await store.upsert(original)

        var duplicate = sqliteItem(storeItemID: "1", title: "Updated")
        duplicate.id = UUID()
        let stored = try await store.upsert(duplicate)

        #expect(stored.id == original.id)
        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == original.id)
        #expect(loaded[0].title == "Updated")
    }

    @Test func deleteCreatesDirtyTombstone() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "1", title: "Delete me")
        try await store.upsert(item)
        try await store.delete(id: item.id)

        #expect(try await store.loadAll().isEmpty)
        let name = CloudRecordIdentity.recordName(for: item.identityKey)
        let record = try #require(try await store.localRecord(named: name))
        #expect(record.isTombstone)
        #expect(record.isDirty)
    }

    @Test func clearingStaleSystemFieldsPreservesPendingLocalItem() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "stale", title: "Pending edit")
        let recordName = CloudRecordIdentity.recordName(for: item.identityKey)
        let staleSystemFields = Data("development-change-tag".utf8)
        try await store.applyRemote(
            recordName: recordName,
            identityKey: item.identityKey,
            item: item,
            isTombstone: false,
            systemFields: staleSystemFields,
            dirty: true
        )

        try await store.clearSystemFields(named: recordName)

        let recovered = try #require(try await store.localRecord(named: recordName))
        #expect(recovered.item?.id == item.id)
        #expect(recovered.item?.identityKey == item.identityKey)
        #expect(recovered.item?.title == item.title)
        #expect(recovered.isDirty)
        #expect(!recovered.isTombstone)
        #expect(recovered.systemFields == nil)

        let recreated = try CloudRecordCodec.makeRecord(
            from: recovered,
            zoneID: CKRecordZone.ID(
                zoneName: CloudRecordIdentity.zoneName,
                ownerName: CKCurrentUserDefaultName
            )
        )
        #expect(recreated.recordChangeTag == nil)
    }

    @Test func migrationIsVerifiedIdempotentAndKeepsJSON() async throws {
        let (store, directory) = makeSQLiteStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("items.json")
        var legacyItem = sqliteItem(storeItemID: "1", title: "Legacy")
        legacyItem.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        legacyItem.updatedAt = legacyItem.createdAt
        let items = [legacyItem]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let originalData = try encoder.encode(items)
        try originalData.write(to: legacyURL)

        #expect(try await store.migrateLegacyJSONIfNeeded(from: legacyURL) == .migrated(1))
        #expect(try await store.migrateLegacyJSONIfNeeded(from: legacyURL) == .alreadyCompleted)
        #expect(try Data(contentsOf: legacyURL) == originalData)
        #expect(try await store.loadAll() == items)
    }

    @Test func failedMigrationDoesNotSetCompletionMarker() async throws {
        let (store, directory) = makeSQLiteStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("items.json")
        try Data("not-json".utf8).write(to: legacyURL)

        await #expect(throws: (any Error).self) {
            _ = try await store.migrateLegacyJSONIfNeeded(from: legacyURL)
        }
        #expect(try await store.metadataData(for: SQLiteItemStore.migrationMetadataKey) == nil)
    }
}

extension SQLiteItemStoreTests {
    @Test func observationAndItemCommitTogetherAndEncodingFailureRollsBack() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "history", title: "Original")
        try await store.upsert(item)
        var changed = item
        changed.title = "Should roll back"
        let invalid = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: .infinity), priceCents: 100, currency: "EUR", isOnSale: false)
        await #expect(throws: (any Error).self) { _ = try await store.upsert(changed, observation: invalid) }
        #expect(try await store.item(id: item.id)?.title == "Original")
        #expect(try await store.observations(for: item.identityKey).isEmpty)
    }

    @Test func remoteUpdatesDoNotInventOrEraseLocalObservations() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "history", title: "Original")
        let observation = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 100), priceCents: 100, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: observation)
        // Retrying the same observation must not duplicate it.
        try await store.upsert(item, observation: observation)
        var remote = item
        remote.id = UUID()
        remote.lastSuccessAt = Date(timeIntervalSince1970: 200)
        remote.priceCurrentCents = 200
        try await store.applyRemote(recordName: CloudRecordIdentity.recordName(for: item.identityKey), identityKey: item.identityKey,
            item: remote, isTombstone: false, systemFields: Data(), dirty: false)
        #expect(try await store.observations(for: item.identityKey) == [observation])
        let record = try #require(try await store.localRecord(named: CloudRecordIdentity.recordName(for: item.identityKey)))
        let cloud = try CloudRecordCodec.makeRecord(from: record, zoneID: CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName))
        #expect(!cloud.allKeys().contains("observations"))
        #expect(cloud[CloudRecordFields.lastSuccessAt] as? Date == remote.lastSuccessAt)
    }
}
