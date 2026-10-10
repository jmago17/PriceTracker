import CloudKit
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

struct PageTextAndVariantTests {
    @Test func jsonLDSizeAndColorAndVisibleTextAreExtracted() throws {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@type":"Product","name":"Chaqueta","size":"M","color":{"name":"Verde oliva"},
         "offers":{"price":"89.95","priceCurrency":"EUR"}}
        </script>
        <style>.x{color:red}</style>
        </head><body><nav>Menú</nav><main><h1>Chaqueta acolchada</h1>
        <p>Relleno sintético reciclado &amp; capucha recogible.</p><script>track()</script></main></body></html>
        """
        let metadata = try #require(StorePageParser.parse(
            data: Data(html.utf8),
            fallbackURL: URL(string: "https://tienda.example/chaqueta")!
        ))

        #expect(metadata.size == "M")
        #expect(metadata.color == "Verde oliva")
        let text = try #require(metadata.pageText)
        #expect(text.contains("Chaqueta acolchada"))
        #expect(text.contains("Relleno sintético reciclado & capucha recogible."))
        #expect(!text.contains("track()"))
        #expect(!text.contains("Menú"))
    }

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

    @Test func pageCapturePropertyListCarriesVariantAndText() throws {
        let capture = try #require(SharedPageCapture(propertyList: [
            "pageURL": "https://tienda.example/p",
            "title": "Producto",
            "size": " 42 ",
            "color": "Azul",
            "pageText": "Texto de la ficha",
        ]))
        #expect(capture.size == "42")
        #expect(capture.color == "Azul")
        #expect(capture.pageText == "Texto de la ficha")
    }
}

struct SummaryCloudCodecTests {
    @Test func summaryAndVariantRoundTripThroughCloudKitRecord() throws {
        let zoneID = CKRecordZone.ID(zoneName: CloudRecordIdentity.zoneName, ownerName: CKCurrentUserDefaultName)
        let item = Item(
            store: .generic,
            storeItemID: "https://tienda.example/p",
            canonicalURL: URL(string: "https://tienda.example/p")!,
            title: "Producto",
            summary: "Resumen breve.",
            size: "M",
            color: "Rojo"
        )
        let local = LocalItemRecord(
            recordName: CloudRecordIdentity.recordName(for: item.identityKey),
            identityKey: item.identityKey,
            item: item,
            isTombstone: false,
            isDirty: true,
            systemFields: nil
        )
        let record = try CloudRecordCodec.makeRecord(from: local, zoneID: zoneID)
        let decoded = try CloudRecordCodec.item(from: record, preservingDeviceFieldsFrom: nil)

        #expect(decoded.summary == "Resumen breve.")
        #expect(decoded.size == "M")
        #expect(decoded.color == "Rojo")
    }
}
