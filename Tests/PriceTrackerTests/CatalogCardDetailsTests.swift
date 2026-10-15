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
        #expect(CatalogCardDetails.metadata(for: value) == "\(value.store.displayName) · Talla M · Verde oliva")
        #expect(CatalogCardDetails.subtitle(for: value) == "Editorial")
        #expect(value.title == "Original")
        #expect(value.subtitle?.contains("Editorial") == true)
    }

    @Test func handlesMissingBlankAndRepeatedCategory() {
        var value = item()
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        value.category = "Libros"
        value.subtitle = "  libros ·  \n "
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        #expect(CatalogCardDetails.subtitle(for: value) == nil)
        value.subtitle = "Autor diferente"
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        #expect(CatalogCardDetails.subtitle(for: value) == "Autor diferente")
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
    @Test func longStoreDescriptionStaysOutOfPriceColumnAndDeduplicatesSummary() {
        var value = item()
        value.category = "Electrónica"
        let description = "Compra online XGIMI proyector. Envío en 1 día GRATIS."
        value.subtitle = "\(value.store.displayName) · Electrónica · \(description)"
        #expect(CatalogCardDetails.metadata(for: value) == value.store.displayName)
        #expect(CatalogCardDetails.subtitle(for: value) == description)
        value.summary = description.uppercased().replacingOccurrences(of: " ", with: "  ")
        #expect(CatalogCardDetails.subtitle(for: value) == nil)
        value.summary = "Proyector portátil con altavoces integrados."
        #expect(CatalogCardDetails.subtitle(for: value) == description)
        value.summary = value.subtitle
        #expect(CatalogCardDetails.subtitle(for: value) == nil)
        #expect(value.category == "Electrónica")
    }

}

#if canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
struct CatalogSummaryLayoutTests {
    @Test func longSummariesStopAtThreeLinesWithoutReservingSpaceForShortOnes() {
        for width: CGFloat in [180, 320, 600] {
            for typeSize: DynamicTypeSize in [.large, .accessibility3] {
                for trailingImage in [false, true] {
                    func height(_ summary: String) -> CGFloat {
                        let item = Item(store: .appStore, storeItemID: "layout",
                                        canonicalURL: URL(string: "https://example.com/layout")!,
                                        title: "Artículo", summary: summary)
                        let card = CompactMuralCardView(item: item, imageOnTrailingSide: trailingImage)
                            .environment(\.dynamicTypeSize, typeSize)
                        let host = UIHostingController(rootView: card)
                        return host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
                    }
                    let three = height("A\nB\nC")
                    let long = height("A\nB\nC\nD\nE\nF\nG\nH")
                    #expect(abs(three - long) < 1)
                    #expect(height("A") < three)
                }
            }
        }
    }
}
#endif
