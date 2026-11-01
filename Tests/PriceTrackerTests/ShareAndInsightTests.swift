import Foundation
import Testing
@testable import PriceTracker

struct ItemShareFormatterTests {
    private func item(_ title: String, size: String? = nil, color: String? = nil, url: String) -> Item {
        Item(
            store: .generic,
            storeItemID: url,
            canonicalURL: URL(string: url)!,
            title: title,
            size: size,
            color: color
        )
    }

    @Test func bulletListIncludesVariantOnlyWhenKnown() {
        let text = ItemShareFormatter.text(for: [
            item("Chaqueta acolchada", size: "M", color: "Verde oliva", url: "https://tienda.example/chaqueta"),
            item("Auriculares", color: "Negro", url: "https://tienda.example/auriculares"),
            item("Lámpara", url: "https://tienda.example/lampara"),
        ])

        #expect(text == """
        • Chaqueta acolchada — Talla M · Verde oliva — https://tienda.example/chaqueta
        • Auriculares — Negro — https://tienda.example/auriculares
        • Lámpara — https://tienda.example/lampara
        """)
    }

    @Test func blankVariantFieldsAreIgnored() {
        let value = item("Zapatillas", size: "  ", color: "", url: "https://tienda.example/z")
        #expect(value.variantDescription == nil)
        #expect(ItemShareFormatter.message(for: value) == "Zapatillas")
    }
}

struct ProductInsightCleanerTests {
    @Test func insightCleanerDropsMenuNoiseAndDuplicates() {
        let cleaned = ProductInsightGenerator.cleaned("""
        Inicio
        OK
        Chaqueta ligera con capucha
        Chaqueta ligera con capucha
        Lavable a máquina a 30 grados
        """)
        #expect(cleaned == "Chaqueta ligera con capucha\nLavable a máquina a 30 grados")
    }
}
