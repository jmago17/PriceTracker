import Foundation
import Testing
@testable import PriceTracker

struct SiriIntentLogicTests {
    @Test func priceSummaryUsesActualCurrency() {
        var item = sampleItem(title: "Procreate", current: 1299, atAdd: 1499)
        item.currency = "USD"
        let summary = GetItemPriceIntent.spokenSummary(for: item)
        #expect(summary.contains("$"))
        #expect(!summary.contains("€"))
    }

    @Test func dropsAreSortedByBiggestAbsoluteSaving() {
        let small = sampleItem(title: "Pequeña", current: 900, atAdd: 1000)
        let large = sampleItem(title: "Grande", current: 2000, atAdd: 3000)
        let unchanged = sampleItem(title: "Igual", current: 500, atAdd: 500)

        let result = ShowPriceDropsIntent.discountedItems(in: [small, unchanged, large])
        #expect(result.map(\.title) == ["Grande", "Pequeña"])
    }

    @Test func refreshSummaryIsConversational() {
        #expect(RefreshCatalogIntent.spokenSummary(for: RefreshSummary()) == "No hay artículos que comprobar.")
        #expect(RefreshCatalogIntent.spokenSummary(for: RefreshSummary(checked: 5, dropped: 1))
            == "Comprobados 5 artículos. Uno ha bajado de precio.")
    }

    private func sampleItem(title: String, current: Int, atAdd: Int) -> Item {
        Item(
            store: .appStore,
            storeItemID: UUID().uuidString,
            currency: "EUR",
            canonicalURL: URL(string: "https://apps.apple.com/us/app/example/id123")!,
            title: title,
            priceCurrentCents: current,
            priceAtAddCents: atAdd
        )
    }
}
