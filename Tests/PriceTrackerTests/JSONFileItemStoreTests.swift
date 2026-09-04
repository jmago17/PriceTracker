import Foundation
import Testing
@testable import PriceTracker

private func makeTempStore() -> JSONFileItemStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return JSONFileItemStore(fileURL: dir.appendingPathComponent("items.json"))
}

private func makeItem(title: String = "Hades II", storeItemID: String = "111") -> Item {
    Item(
        store: .appStore,
        storeItemID: storeItemID,
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id\(storeItemID)")!,
        title: title
    )
}

struct JSONFileItemStoreTests {
    @Test func loadAllOnMissingFileReturnsEmpty() async throws {
        let store = makeTempStore()
        let items = try await store.loadAll()
        #expect(items.isEmpty)
    }

    @Test func saveThenLoadRoundTrips() async throws {
        let store = makeTempStore()
        // A fixed date, not `Date()`: JSON's `secondsSince1970` round trip does
        // not guarantee bit-exact `Double` precision, and this test cares about
        // real content surviving a save/load cycle, not float formatting.
        var item = makeItem()
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        item.updatedAt = item.createdAt

        try await store.save([item])
        let loaded = try await store.loadAll()
        #expect(loaded == [item])
    }

    @Test func upsertInsertsNewItem() async throws {
        let store = makeTempStore()
        let item = makeItem()
        try await store.upsert(item)
        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == item.id)
    }

    @Test func upsertByIdenticalIdentityKeyIsIdempotent() async throws {
        // Adding the same store URL twice must not create two rows — the
        // architecture's `UNIQUE (store, store_item_id, region)` rule.
        let store = makeTempStore()
        let first = makeItem(title: "Hades II")
        try await store.upsert(first)

        var duplicate = makeItem(title: "Hades II (recheck)")
        duplicate.id = UUID() // simulates re-resolving the same URL, a fresh Item value

        try await store.upsert(duplicate)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == first.id, "the original id must be preserved, not the duplicate's")
        #expect(loaded.first?.title == "Hades II (recheck)", "but its fields should be refreshed")
    }

    @Test func deleteRemovesItem() async throws {
        let store = makeTempStore()
        let item = makeItem()
        try await store.upsert(item)
        try await store.delete(id: item.id)
        let loaded = try await store.loadAll()
        #expect(loaded.isEmpty)
    }
}
