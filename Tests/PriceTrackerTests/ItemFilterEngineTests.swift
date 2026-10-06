import Foundation
import Testing
@testable import PriceTracker

private func makeItem(title: String, store: Store = .appStore, category: String? = nil, priceCurrentCents: Int? = nil, lastCheckedAt: Date? = nil) -> Item {
    Item(
        store: store,
        storeItemID: title,
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id\(abs(title.hashValue))")!,
        title: title,
        category: category,
        priceCurrentCents: priceCurrentCents,
        lastCheckedAt: lastCheckedAt
    )
}

/// Exercises the pure engine behind the `EntityPropertyQuery` used by the
/// "Buscar Artículos" Shortcuts action — see AppIntents/ItemQuery.swift.
struct ItemFilterEngineTests {
    @Test func filterWithNoPredicatesReturnsEverything() {
        let items = [makeItem(title: "A"), makeItem(title: "B")]
        let result = ItemFilterEngine.filter(items, predicates: [], mode: .and)
        #expect(result.count == 2)
    }

    @Test func filterAndRequiresAllPredicates() {
        let items = [
            makeItem(title: "A", store: .appStore, category: "Juegos"),
            makeItem(title: "B", store: .appStore, category: "Apps"),
            makeItem(title: "C", store: .amazon, category: "Juegos"),
        ]
        let predicates: [@Sendable (Item) -> Bool] = [
            { $0.store == .appStore },
            { $0.category == "Juegos" },
        ]
        let result = ItemFilterEngine.filter(items, predicates: predicates, mode: .and)
        #expect(result.map(\.title) == ["A"])
    }

    @Test func filterOrRequiresAnyPredicate() {
        let items = [
            makeItem(title: "A", store: .appStore),
            makeItem(title: "B", store: .amazon),
            makeItem(title: "C", store: .eshop),
        ]
        let predicates: [@Sendable (Item) -> Bool] = [
            { $0.store == .appStore },
            { $0.store == .amazon },
        ]
        let result = ItemFilterEngine.filter(items, predicates: predicates, mode: .or)
        #expect(Set(result.map(\.title)) == Set(["A", "B"]))
    }

    @Test func categoryFilterSupportsNamedAndUncategorizedItems() {
        let items = [
            makeItem(title: "Game", category: "Juegos"),
            makeItem(title: "Tool", category: "Utilidades"),
            makeItem(title: "Loose"),
        ]

        #expect(ItemFilterEngine.filter(items, by: .all).count == 3)
        #expect(ItemFilterEngine.filter(items, by: .category("Juegos")).map(\.title) == ["Game"])
        #expect(ItemFilterEngine.filter(items, by: .uncategorized).map(\.title) == ["Loose"])
    }

    @Test func categoryNamesAreUniqueAndLocalizedCaseInsensitiveSorted() {
        let items = [
            makeItem(title: "1", category: "Utilidades"),
            makeItem(title: "2", category: "Juegos"),
            makeItem(title: "3", category: "Utilidades"),
            makeItem(title: "4"),
        ]

        #expect(ItemFilterEngine.categoryNames(in: items) == ["Juegos", "Utilidades"])
    }

    @Test func sortByTitleAscendingIsCaseInsensitive() {
        let items = [makeItem(title: "banana"), makeItem(title: "Apple"), makeItem(title: "cherry")]
        let sorted = ItemFilterEngine.sort(items, by: .title, ascending: true)
        #expect(sorted.map(\.title) == ["Apple", "banana", "cherry"])
    }

    @Test func sortByLastCheckedAtOldestFirst() {
        let now = Date()
        let items = [
            makeItem(title: "recent", lastCheckedAt: now),
            makeItem(title: "never checked", lastCheckedAt: nil),
            makeItem(title: "old", lastCheckedAt: now.addingTimeInterval(-3600)),
        ]
        let sorted = ItemFilterEngine.sort(items, by: .lastCheckedAt, ascending: true)
        // nil (.distantPast) sorts first — exactly the "most stale first" the
        // architecture wants for the FindItems → RefreshItem loop.
        #expect(sorted.map(\.title) == ["never checked", "old", "recent"])
    }

    @Test func sortByPriceDescending() {
        let items = [
            makeItem(title: "cheap", priceCurrentCents: 500),
            makeItem(title: "no price", priceCurrentCents: nil),
            makeItem(title: "expensive", priceCurrentCents: 9999),
        ]
        let sorted = ItemFilterEngine.sort(items, by: .priceCurrent, ascending: false)
        #expect(sorted.first?.title == "no price", "items with no price sort as +infinity, so descending puts them first")
    }

    @Test func limitCapsResultCount() {
        let items = (0..<10).map { makeItem(title: "item\($0)") }
        let limited = ItemFilterEngine.limit(items, to: 3)
        #expect(limited.count == 3)
    }

    @Test func limitNilReturnsEverything() {
        let items = (0..<5).map { makeItem(title: "item\($0)") }
        #expect(ItemFilterEngine.limit(items, to: nil).count == 5)
    }
}


struct CatalogSemanticsTests {
    @Test func categoryIdentityAndCaseTiesRemainStable() {
        let input = [makeItem(title: "A", category: "libros"), makeItem(title: "B", category: "Libros"), makeItem(title: "C", category: "Sin categoría"), makeItem(title: "D")]
        let sections = ItemFilterEngine.sections(in: input)
        #expect(Array(sections.prefix(2)).map(\.title) == ["Libros", "libros"])
        #expect(Set(sections.map(\.id)).count == 4)
        #expect(sections.last?.category == nil)
    }

    @Test func groupingPreservesOrderAndUnknownNames() {
        let input = [makeItem(title: "Z", category: "Nueva categoría"), makeItem(title: "B", category: " Libros "), makeItem(title: "A", category: "Libros"), makeItem(title: "Vacío", category: "  "), makeItem(title: "Nulo")]
        let sections = ItemFilterEngine.sections(in: input)
        #expect(sections.map(\.title) == ["Libros", "Nueva categoría", "Sin categoría"])
        #expect(sections[0].items.map(\.title) == ["B", "A"])
        #expect(sections[2].items.count == 2)
        #expect(Set(sections.map(\.id)).count == 3)
        #expect(ItemFilterEngine.sections(in: []).isEmpty)
        let filtered = ItemFilterEngine.filter(input, by: .category("Libros"))
        #expect(ItemFilterEngine.sections(in: filtered).count == 1)
        #expect(ItemFilterEngine.filter(input, by: .uncategorized).count == 2)
    }

    @Test func groupingUsesOnlySearchResultsAndKeepsRequestedSort() {
        let input = [makeItem(title: "B juego", category: "Juegos"), makeItem(title: "A juego", category: "Juegos"), makeItem(title: "Libro", category: "Libros")]
        let found = ItemFilterEngine.filter(input, predicates: [{ $0.title.contains("juego") }], mode: .and)
        let sorted = ItemFilterEngine.sort(found, by: .title, ascending: false)
        let sections = ItemFilterEngine.sections(in: sorted)
        #expect(sections.map(\.title) == ["Juegos"])
        #expect(sections[0].items.map(\.title) == ["B juego", "A juego"])
    }

    @Test func historicalReductionNeverExpiresOrUsesReferenceAsPromotion() {
        var item = makeItem(title: "Permanent reduction", priceCurrentCents: 500)
        item.priceAtAddCents = 1000
        item.priceReferenceCents = 2000
        item.createdAt = .distantPast
        #expect(item.reductionSinceAddedCents == 500)
        item.priceAtAddCents = nil
        #expect(item.reductionSinceAddedCents == nil)
        item.priceAtAddCents = 500
        #expect(item.reductionSinceAddedCents == nil)
        item.priceCurrentCents = 0
        #expect(item.reductionSinceAddedCents == 500)
        item.priceCurrentCents = -1
        #expect(item.reductionSinceAddedCents == nil)
    }
}
