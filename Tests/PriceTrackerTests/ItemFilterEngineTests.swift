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
