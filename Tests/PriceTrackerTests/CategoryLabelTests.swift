import Foundation
import Testing
@testable import PriceTracker

struct CategoryLabelTests {
    @Test func safeSuggestionsHaveAtMostTwoWords() {
        for name in ["Hogar y cocina", "Deportes y aire libre", "Cuidado personal", "Libros"] {
            let label = CategoryLabel.suggestion(name)
            #expect(label != nil)
            #expect(CategoryLabel.wordCount(label!) <= 2)
        }
        #expect(CategoryLabel.suggestion("Accesorios especiales para cámaras de cine") == nil)
        #expect(CategoryLabel.suggestion("  ") == nil)
    }

    @Test func oldNamesRemainEditableWithoutDestructiveTruncation() {
        let original = "Accesorios especiales para cámaras de cine"
        #expect(CategoryLabel.displayName(original) == original)
        #expect(CategoryLabel.allowsEdit(original, original: original))
        #expect(!CategoryLabel.allowsEdit("Nueva categoría demasiado larga", original: original))
        #expect(CategoryLabel.allowsEdit("Cine profesional", original: original))
        #expect(CategoryLabel.displayName(nil) == "Sin categoría")
    }
    @Test func equalDisplayAliasesNeverMergeFilterIdentities() {
        let first = Item(store: .generic, storeItemID: "1", canonicalURL: URL(string: "https://example.com/1")!, title: "Uno", category: "Hogar y cocina")
        let second = Item(store: .generic, storeItemID: "2", canonicalURL: URL(string: "https://example.com/2")!, title: "Dos", category: "Hogar/Cocina")
        #expect(CategoryLabel.displayName(first.category) == CategoryLabel.displayName(second.category))
        let names = [first.category!, second.category!]
        #expect(CategoryLabel.displayName(first.category, among: names) != CategoryLabel.displayName(second.category, among: names))
        #expect(ItemFilterEngine.sections(in: [first, second]).count == 2)
        #expect(ItemFilterEngine.filter([first, second], by: .category(first.category!)).map(\.id) == [first.id])
        #expect(first.category == "Hogar y cocina")
    }

    @Test func importAndRefreshPreserveOriginalGenreAndExistingIdentity() {
        let raw = "Accesorios especiales para cámaras de cine"
        var resolved = ResolvedItem(store: .generic, storeItemID: "new", region: "ES", currency: "EUR", canonicalURL: URL(string: "https://example.com/new")!, title: "Cámara", priceCents: 1000, storeGenre: raw)
        let imported = Item(resolved: resolved)
        #expect(imported.category == nil)
        #expect(imported.storeGenre == raw)
        resolved.storeGenre = "Hogar y cocina"
        #expect(Item(resolved: resolved).category == "Hogar/Cocina")
        var existing = imported
        existing.category = raw
        existing.categorySource = .mapped
        let fetch = FetchResult(priceCents: 1000, currency: "EUR", isOnSale: false, availability: "available", storeGenre: "Hogar y cocina")
        #expect(PriceDropDetector.evaluate(item: existing, fetch: fetch).updatedItem.category == raw)
        #expect(PriceDropDetector.evaluate(item: imported, fetch: fetch).updatedItem.category == "Hogar/Cocina")
    }

}
