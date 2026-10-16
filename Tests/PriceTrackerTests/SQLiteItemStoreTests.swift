import CloudKit
import Foundation
import Testing
@testable import PriceTracker

struct HistorySyncTests {
    private let zone = CKRecordZone.ID(zoneName: "HistoryTests", ownerName: CKCurrentUserDefaultName)

    private func transfer(_ source: SQLiteItemStore, to target: SQLiteItemStore) async throws {
        for local in try await source.observationRecords(dirtyOnly: true) {
            let record = try CloudObservationCodec.makeRecord(local, zoneID: zone)
            let accepted = try CloudObservationCodec.decode(record)
            try await target.applyRemoteObservation(accepted)
            try await source.applyRemoteObservation(accepted)
        }
    }

    @Test func disabledHistoryTransportRetainsSamplesAcrossCatalogAcknowledgementAndRestart() async throws {
        let (store, directory) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "gate", title: "Catalog remains eligible")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 1000), priceCents: 100, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: point)
        let catalog = try #require(try await store.dirtyRecords().first)
        let names = try await store.dirtyObservationNames()
        let pending = ([catalog.recordName] + names).map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zone)) }
        #expect(pending.filter(HistoryTransportPolicy.permits).count == 1)
        let accepted = try CloudRecordCodec.archivedSystemFields(CloudRecordCodec.makeRecord(from: catalog, zoneID: zone))
        _ = try await store.acknowledgeSavedRecord(named: catalog.recordName, systemFields: accepted, matchesCurrentLocalValue: true)
        let reopened = SQLiteItemStore(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        #expect(try await reopened.dirtyCount() == 0)
        #expect(try await reopened.observationRecords(dirtyOnly: true).first?.observation == point)
        #expect(try await reopened.observations(for: item.identityKey) == [point])
    }

    @Test func upgradeDoesNotReuseCursorWrittenByHistoryUnawareClient() async throws {
        let (store, _) = makeSQLiteStore()
        let old = Data("old client advanced past unknown history records".utf8)
        try await store.setMetadataData(old, for: "ck-sync-engine-state-v1")
        #expect(try await store.metadataData(for: SQLiteItemStore.syncStateMetadataKey) == nil)
        let new = Data("new history-aware cursor".utf8)
        try await store.setMetadataData(new, for: SQLiteItemStore.syncStateMetadataKey)
        try await store.setMetadataData(Data("downgraded client cursor".utf8), for: "ck-sync-engine-state-v1")
        #expect(try await store.metadataData(for: SQLiteItemStore.syncStateMetadataKey) == new)
    }

    @Test func conflictingIncomingRecordRemainsDurableWhileOtherSamplesApply() async throws {
        let (store, directory) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "retained", title: "Retained conflict")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 9000), priceCents: 100, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: point)
        var conflict = try #require(try await store.observationRecords().first)
        conflict.observation?.priceCents = 999
        let server = try CloudObservationCodec.makeRecord(conflict, zoneID: zone)
        let archive = try CloudRecordCodec.archivedSystemFields(server)
        try await store.retainIncomingRecord(named: conflict.recordName, archive: archive)
        do { try await store.applyRemoteObservation(CloudObservationCodec.decode(server)) } catch {}
        var other = point
        other.id = UUID(); other.currency = "USD"
        let record = LocalObservationRecord(recordName: CloudObservationCodec.recordName(identityKey: item.identityKey, id: other.id), identityKey: item.identityKey, observation: other, isTombstone: false, isDirty: false, systemFields: nil)
        try await store.applyRemoteObservation(record)
        let reopened = SQLiteItemStore(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        #expect(try await reopened.observations(for: item.identityKey).count == 2)
        let retained = try #require(try await reopened.retainedIncomingRecords().first)
        let decoded = try CloudObservationCodec.decode(CloudRecordCodec.record(fromSystemFields: retained))
        #expect(decoded.observation?.priceCents == 999)
        #expect(try await reopened.observations(for: item.identityKey).first(where: { $0.id == point.id })?.priceCents == 100)
    }

    @Test func unknownPhysicalDeletionWinsOverLateOfflineSample() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "late", title: "Late sample")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 6000), priceCents: 50, currency: "EUR", isOnSale: false)
        let name = CloudObservationCodec.recordName(identityKey: item.identityKey, id: point.id)
        try await store.tombstoneObservation(named: name)
        try await store.applyRemoteObservation(LocalObservationRecord(recordName: name, identityKey: item.identityKey, observation: point, isTombstone: false, isDirty: false, systemFields: nil))
        try await store.upsert(item)
        #expect(try await store.observations(for: item.identityKey).isEmpty)
        #expect(try await store.observationRecords(named: name).first?.observation?.id == point.id)
        #expect(try await store.observationRecords(named: name).first?.isDirty == true)
    }

    @Test func offlineDevicesUnionRealSamplesAndRetriesDoNotDuplicate() async throws {
        let (a, _) = makeSQLiteStore()
        let (b, _) = makeSQLiteStore()
        let itemA = sqliteItem(storeItemID: "union", title: "History")
        var itemB = itemA
        itemB.id = UUID()
        let first = PriceObservation(itemID: itemA.id, checkedAt: Date(timeIntervalSince1970: 1000), priceCents: 1000, currency: "EUR", isOnSale: false)
        var second = first
        second.id = UUID(); second.itemID = itemB.id
        second.checkedAt = Date(timeIntervalSince1970: 2000); second.priceCents = 800
        try await a.upsert(itemA, observation: first)
        try await b.upsert(itemB, observation: second)
        try await transfer(a, to: b)
        try await transfer(b, to: a)
        // Fetching the same server records again is idempotent.
        for local in try await a.observationRecords() {
            let remote = try CloudObservationCodec.decode(CloudObservationCodec.makeRecord(local, zoneID: zone))
            try await b.applyRemoteObservation(remote)
            try await b.applyRemoteObservation(remote)
        }
        let pointsA = try await a.observations(for: itemA.identityKey)
        let pointsB = try await b.observations(for: itemA.identityKey)
        #expect(pointsA.map(\.id) == [first.id, second.id])
        #expect(pointsB.map(\.id) == pointsA.map(\.id))
        #expect(pointsA.map(\.priceCents) == [1000, 800])
        #expect(pointsB.allSatisfy { $0.itemID == itemB.id })
        #expect(try await a.observationRecords(dirtyOnly: true).isEmpty)
        #expect(try await b.observationRecords(dirtyOnly: true).isEmpty)
    }

    @Test func migrationAndRestartPreserveUUIDDatesCurrencyAndPendingSamples() async throws {
        let (store, directory) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "migration", title: "Old history")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 1234.25), priceCents: 0, currency: "USD", isOnSale: false)
        try await store.upsert(item, observation: point)
        // Local writes retain the old schema; discovery adds only sync metadata.
        try await store.prepareObservationSync()
        try await store.prepareObservationSync()
        let reopened = SQLiteItemStore(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        let pending = try await reopened.observationRecords(dirtyOnly: true)
        #expect(pending.count == 1)
        #expect(pending.first?.observation == point)
        try await reopened.resetObservationSystemFields(named: pending[0].recordName)
        #expect(try await reopened.observationRecords(dirtyOnly: true).first?.observation == point)
    }

    @Test func samplesArrivingBeforeItemAndTombstonesNeverResurrectHistory() async throws {
        let (source, _) = makeSQLiteStore()
        let (target, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "ordering", title: "Ordering")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 3000), priceCents: 500, currency: "EUR", isOnSale: false)
        try await source.upsert(item, observation: point)
        let local = try #require(try await source.observationRecords().first)
        let remote = try CloudObservationCodec.decode(CloudObservationCodec.makeRecord(local, zoneID: zone))
        try await target.applyRemoteObservation(remote)
        try await target.upsert(item)
        #expect(try await target.observations(for: item.identityKey).count == 1)
        try await target.delete(id: item.id)
        #expect(try await target.observations(for: item.identityKey).isEmpty)
        #expect(try await target.observationRecords().first?.observation?.id == point.id)
        try await target.tombstoneObservation(named: local.recordName)
        try await target.applyRemoteObservation(remote)
        #expect(try await target.observationRecords(named: local.recordName).first?.isTombstone == true)
        #expect(try await target.observationRecords(named: local.recordName).first?.isDirty == true)
    }

    @Test func conflictingImmutableUUIDFailsWithoutDiscardingLocalSample() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "conflict", title: "Conflict")
        let point = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 5000), priceCents: 100, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: point)
        var remote = try #require(try await store.observationRecords().first)
        remote.observation?.priceCents = 999
        do {
            try await store.applyRemoteObservation(remote)
            Issue.record("Conflicting sample must not overwrite history")
        } catch {}
        #expect(try await store.observations(for: item.identityKey).first?.priceCents == 100)
    }
}

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
        #expect(try await store.item(id: item.id)?.priceCurrentCents == remote.priceCurrentCents)
        #expect(try await store.item(id: remote.id) == nil)
        let record = try #require(try await store.localRecord(named: CloudRecordIdentity.recordName(for: item.identityKey)))
        let cloud = try CloudRecordCodec.makeRecord(from: record, zoneID: CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName))
        #expect(!cloud.allKeys().contains("observations"))
        #expect(cloud[CloudRecordFields.lastSuccessAt] as? Date == remote.lastSuccessAt)
    }
}
