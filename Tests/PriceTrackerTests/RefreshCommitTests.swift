import Foundation
import Testing
@testable import PriceTracker

private func commitItem(_ id: String = "1", price: Int = 1000) -> Item {
    Item(store: .appStore, storeItemID: id, region: "FR", currency: "EUR",
         canonicalURL: URL(string: "https://apps.apple.com/fr/app/id\(id)")!, title: "Item \(id)",
         priceCurrentCents: price, priceAtAddCents: 2000, priceReferenceCents: 2500, priceLowCents: price)
}

struct RefreshCommitTests {
    @Test func refreshCommitRejectsDeletedOrConcurrentlyEditedRows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-\(UUID()).sqlite")
        let store = SQLiteItemStore(databaseURL: url)
        let otherConnection = SQLiteItemStore(databaseURL: url)
        let item = commitItem()
        try await store.upsert(item)
        var updated = item; updated.priceCurrentCents = 500
        let observation = PriceObservation(itemID: item.id, checkedAt: Date(), priceCents: 500,
                                           currency: "EUR", isOnSale: false)
        var edited = item; edited.notes = "Keep this concurrent edit"
        try await otherConnection.upsert(edited)
        await #expect(throws: RefreshCommitError.self) {
            try await store.commitRefresh(updated, expected: item, observation: observation)
        }
        #expect(try await store.item(id: item.id)?.notes == edited.notes)
        #expect(try await store.observations(for: item.identityKey).isEmpty)
        try await otherConnection.delete(id: item.id)
        await #expect(throws: RefreshCommitError.self) {
            try await store.commitRefresh(updated, expected: edited, observation: observation)
        }
        #expect(try await store.item(id: item.id) == nil)
        #expect(try await ItemQuery(store: store).entities(for: [item.id]).isEmpty)
    }

    @Test func refreshResultEntityReportsSuccessAndFailure() {
        let id = UUID()
        let ok = RefreshResultEntity(outcome: ItemRefreshOutcome(
            itemID: id, priceCents: 500, currency: "EUR", changed: true, checkedAt: Date()))
        #expect(ok.success && ok.changed && ok.priceCents == 500 && ok.itemID == id.uuidString)

        let failed = RefreshResultEntity(outcome: ItemRefreshOutcome(itemID: id, error: "Sin conexión"))
        #expect(!failed.success && failed.error == "Sin conexión" && !failed.changed)
    }
}
