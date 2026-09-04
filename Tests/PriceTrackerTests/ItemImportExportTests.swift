import Foundation
import Testing
@testable import PriceTracker

private func makeTempStore() -> JSONFileItemStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return JSONFileItemStore(fileURL: dir.appendingPathComponent("items.json"))
}

private func makeItem(title: String, storeItemID: String) -> Item {
    Item(
        store: .appStore,
        storeItemID: storeItemID,
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id\(storeItemID)")!,
        title: title
    )
}

struct ItemImportExportTests {
    @Test func exportThenImportRoundTrips() async throws {
        let items = [makeItem(title: "A", storeItemID: "1"), makeItem(title: "B", storeItemID: "2")]
        let data = try ItemExporter.exportData(items: items)

        let store = makeTempStore()
        let summary = try await ItemImporter.importData(data, mode: .merge, into: store)

        #expect(summary.imported == 2)
        #expect(summary.skipped == 0)
        let loaded = try await store.loadAll()
        #expect(Set(loaded.map(\.title)) == Set(["A", "B"]))
    }

    @Test func mergeImportIsIdempotentByIdentityKey() async throws {
        let store = makeTempStore()
        let original = makeItem(title: "A", storeItemID: "1")
        try await store.upsert(original)

        var updated = original
        updated.id = UUID() // a fresh export/import round trip won't preserve object identity
        updated.title = "A (renamed)"
        let data = try ItemExporter.exportData(items: [updated])

        let summary = try await ItemImporter.importData(data, mode: .merge, into: store)
        #expect(summary.imported == 1)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1, "same store/store_item_id/region must merge into one row, not duplicate")
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.title == "A (renamed)")
    }

    @Test func replaceImportWipesExistingCatalog() async throws {
        let store = makeTempStore()
        try await store.upsert(makeItem(title: "old", storeItemID: "99"))

        let data = try ItemExporter.exportData(items: [makeItem(title: "new", storeItemID: "1")])
        _ = try await ItemImporter.importData(data, mode: .replace, into: store)

        let loaded = try await store.loadAll()
        #expect(loaded.map(\.title) == ["new"])
    }

    @Test func unsupportedSchemaVersionThrows() async throws {
        let store = makeTempStore()
        let future = CatalogExport(schemaVersion: 999, exportedAt: Date(), items: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(future)

        await #expect(throws: ImportError.self) {
            _ = try await ItemImporter.importData(data, mode: .merge, into: store)
        }
    }

    @Test func legacyImporterIsExplicitlyNotImplemented() async throws {
        let store = makeTempStore()
        await #expect(throws: LegacyImportError.self) {
            _ = try await LegacyImporter.importLegacyShortcutsExport(Data(), into: store)
        }
    }
}
