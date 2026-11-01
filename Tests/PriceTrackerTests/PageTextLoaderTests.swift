import Foundation
import Testing
@testable import PriceTracker

private let sampleHTML = """
<!doctype html>
<html lang="es"><head>
<title>Chaqueta acolchada &amp; ligera | Tienda</title>
<meta charset="utf-8">
<meta name="description" content="Chaqueta de relleno sintético reciclado.">
<meta property="og:description" content="Otra descripción social">
<script>window.dataLayer = [{price: 89.95}];</script>
<style>.precio { color: red }</style>
</head><body>
<nav><a href="/">Inicio</a><a href="/mujer">Mujer</a></nav>
<main>
  <h1>Chaqueta acolchada</h1>
  <p>Relleno sintético reciclado y capucha recogible.</p>
  <ul><li>Lavable a máquina</li><li>Precio: 89&#44;95 &euro;</li></ul>
  <button>Añadir a la cesta</button>
</main>
<footer>Política de cookies</footer>
<script>track('view')</script>
</body></html>
"""

struct PageTextLoaderTests {
    private func loader(status: Int = 200, html: String = sampleHTML) -> (PageTextLoader, FakeTransport) {
        let transport = FakeTransport { _ in (status, html) }
        return (PageTextLoader(transport: transport), transport)
    }

    @Test func extractsTitleMetaDescriptionAndMainText() async throws {
        let (loader, transport) = loader()
        let page = try await loader.load(url: URL(string: "https://tienda.example/chaqueta")!)

        #expect(page.title == "Chaqueta acolchada & ligera | Tienda")
        #expect(page.description == "Chaqueta de relleno sintético reciclado.")
        #expect(page.body.contains("Chaqueta acolchada"))
        #expect(page.body.contains("Relleno sintético reciclado y capucha recogible."))
        #expect(page.body.contains("Lavable a máquina"))
        #expect(page.body.contains("89,95 €"))
        #expect(page.body.components(separatedBy: "\n").contains("Chaqueta acolchada"))
        // Chrome around the product is dropped.
        for noise in ["track(", "dataLayer", "color: red", "Inicio", "Política de cookies", "Añadir a la cesta", "<"] {
            #expect(!page.body.contains(noise), "body still contains \(noise)")
        }
        let request = try #require(transport.requests.first)
        let userAgent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(userAgent.contains("iPhone") && userAgent.contains("Safari"))
    }

    @Test func fallsBackToTheOpenGraphDescriptionAndReadsAttributesInAnyOrder() {
        let page = PageTextLoader.extract(html: """
        <head><meta content='Sólo social' property='og:description'></head><body><p>Texto del producto</p></body>
        """)
        #expect(page.description == "Sólo social")
        #expect(page.body == "Texto del producto")
    }

    @Test func combinedTextIsCutAtSixThousandCharactersOnAWordBoundary() {
        let paragraph = String(repeating: "palabra ", count: 40)
        let html = "<html><head><title>Titulo</title></head><body>"
            + String(repeating: "<p>\(paragraph)</p>", count: 60) + "</body></html>"
        let combined = PageTextLoader.extract(html: html).combined()

        #expect(combined.count <= PageTextLoader.maxCharacters)
        #expect(combined.count > PageTextLoader.maxCharacters - 100)
        #expect(combined.hasPrefix("Titulo\n"))
        #expect(combined.hasSuffix("palabra"))
        #expect(PageText(title: nil, description: nil, body: "corto").combined() == "corto")
    }

    @Test func nonSuccessStatusAndEmptyPagesThrow() async {
        let (blocked, _) = loader(status: 403)
        await #expect(throws: PageTextError.http(403)) {
            try await blocked.load(url: URL(string: "https://tienda.example/x")!)
        }
        let (empty, _) = loader(html: "<html><body><script>x()</script></body></html>")
        await #expect(throws: PageTextError.empty) {
            try await empty.load(url: URL(string: "https://tienda.example/x")!)
        }
        let (other, transport) = loader()
        await #expect(throws: PageTextError.invalidURL) {
            try await other.load(url: URL(string: "file:///etc/hosts")!)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func summarySourceFallsBackToTitleSubtitleAndCategory() {
        let item = Item(store: .generic, storeItemID: "x", canonicalURL: URL(string: "https://tienda.example/x")!,
                        title: "Chaqueta acolchada", subtitle: "Relleno reciclado", category: "Ropa")
        #expect(ItemEnricher.source(page: nil, item: item) == "Chaqueta acolchada\nRelleno reciclado\nRopa")

        let page = PageText(title: "Título de página", description: nil, body: "Texto de la ficha")
        #expect(ItemEnricher.source(page: page, item: item) == "Título de página\nTexto de la ficha")
        // A page with nothing readable does not hide the catalog data.
        #expect(ItemEnricher.source(page: PageText(title: nil, description: nil, body: ""), item: item)
                == "Chaqueta acolchada\nRelleno reciclado\nRopa")
    }
}
