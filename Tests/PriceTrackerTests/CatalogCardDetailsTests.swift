import Foundation
import Testing
@testable import PriceTracker

struct CatalogCardDetailsTests {
    private func item() -> Item {
        Item(store: .appStore, storeItemID: "card", canonicalURL: URL(string: "https://example.com/card")!, title: "Original")
    }

    @Test func preservesSubtitleWithoutRepeatingStoreOrVariant() {
        var value = item()
        value.size = "M"
        value.color = "Verde oliva"
        value.subtitle = "Editorial · \(value.store.displayName.uppercased()) · Talla M · verde   oliva"
        #expect(CatalogCardDetails.metadata(for: value) == "\(value.store.displayName) · Talla M · Verde oliva · Editorial")
        #expect(value.title == "Original")
        #expect(value.subtitle?.contains("Editorial") == true)
    }

    @Test func handlesMissingBlankAndRepeatedCategory() {
        var value = item()
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        value.category = "Libros"
        value.subtitle = "  libros ·  \n "
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        value.subtitle = "Autor diferente"
        #expect(CatalogCardDetails.metadata(for: value).hasSuffix(" · Autor diferente"))
    }

    @Test func targetSurvivesDiscountAndUsesActualCurrencyIncludingZero() {
        var value = item()
        #expect(CatalogCardDetails.targetPrice(for: value) == nil)
        value.priceAtAddCents = 2000
        value.priceCurrentCents = 1000
        value.targetPriceCents = 799
        value.currency = "USD"
        #expect(CatalogCardDetails.targetPrice(for: value) == "Obj. \(MoneyFormatter.string(cents: 799, currency: "USD"))")
        value.targetPriceCents = 0
        #expect(CatalogCardDetails.targetPrice(for: value) == "Obj. \(MoneyFormatter.string(cents: 0, currency: "USD"))")
    }
}
