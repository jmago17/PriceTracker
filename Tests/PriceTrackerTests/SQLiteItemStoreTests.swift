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

    @Test func deleteLeavesTombstoneAndHidesTheItem() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "1", title: "Delete me")
        try await store.upsert(item)
        try await store.delete(id: item.id)

        #expect(try await store.loadAll().isEmpty)
        let record = try #require(try await store.localRecord(named: SQLiteItemStore.recordName(for: item.identityKey)))
        #expect(record.isTombstone)
    }

    @Test func recordNameIsAStableDigestOfTheIdentity() {
        let name = SQLiteItemStore.recordName(for: "appStore|1|ES")
        #expect(name == SQLiteItemStore.recordName(for: "appStore|1|ES"))
        #expect(name != SQLiteItemStore.recordName(for: "appStore|2|ES"))
        #expect(name.hasPrefix("item_") && name.count == 5 + 64)
    }

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

    @Test func retryingTheSameObservationDoesNotDuplicateIt() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "history", title: "Original")
        let observation = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 100), priceCents: 100, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: observation)
        try await store.upsert(item, observation: observation)
        #expect(try await store.observations(for: item.identityKey) == [observation])
    }

    @Test func serverChangesApplyDeletionsReplaceAllAndMetadataTogether() async throws {
        let (store, _) = makeSQLiteStore()
        let keep = sqliteItem(storeItemID: "1", title: "Keep")
        let drop = sqliteItem(storeItemID: "2", title: "Dropped by server")
        let gone = sqliteItem(storeItemID: "3", title: "Deleted by server")
        try await store.applyServerChanges(upserts: [keep, drop, gone], deletedIDs: [], replaceAll: false, metadata: [:])

        try await store.applyServerChanges(
            upserts: [keep], deletedIDs: [gone.id], replaceAll: true,
            metadata: ["cursor": Data("t1".utf8)]
        )

        #expect(try await store.loadAll().map(\.id) == [keep.id])
        #expect(try await store.metadataData(for: "cursor") == Data("t1".utf8))
    }

    @Test func serverChangesKeepTheServerIDOfAKnownIdentity() async throws {
        let (store, _) = makeSQLiteStore()
        let local = sqliteItem(storeItemID: "1", title: "Local")
        try await store.upsert(local)

        var server = local
        server.id = UUID()
        server.title = "Server"
        try await store.applyServerChanges(upserts: [server], deletedIDs: [], replaceAll: false, metadata: [:])

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == server.id && loaded[0].title == "Server")
    }

    @Test func replacingObservationsSwapsTheCachedHistoryOfOneItem() async throws {
        let (store, _) = makeSQLiteStore()
        let item = sqliteItem(storeItemID: "history", title: "Original")
        let other = sqliteItem(storeItemID: "other", title: "Other")
        try await store.upsert(item)
        try await store.upsert(other)
        let old = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 100), priceCents: 100, currency: "EUR", isOnSale: false)
        let unrelated = PriceObservation(itemID: other.id, checkedAt: Date(timeIntervalSince1970: 100), priceCents: 900, currency: "EUR", isOnSale: false)
        try await store.upsert(item, observation: old)
        try await store.upsert(other, observation: unrelated)

        let fresh = PriceObservation(itemID: item.id, checkedAt: Date(timeIntervalSince1970: 200), priceCents: 80, currency: "EUR", isOnSale: false)
        try await store.replaceObservations([fresh], identityKey: item.identityKey)

        #expect(try await store.observations(for: item.identityKey) == [fresh])
        #expect(try await store.observations(for: other.identityKey) == [unrelated])
    }
}
