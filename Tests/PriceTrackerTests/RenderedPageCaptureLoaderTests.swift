import Foundation
import Testing
@testable import PriceTracker

struct RenderedPageCaptureLoaderTests {
    @Test @MainActor func capturesJavaScriptRenderedProductWithoutStoreSpecificRules() async throws {
        let html = """
        <html lang="es"><head><title>Tienda dinámica</title></head><body>
        <main id="product"></main>
        <script>
        setTimeout(() => {
          document.getElementById('product').innerHTML = `
            <h1>Auriculares dinámicos</h1>
            <div class="price--current">19,95 €</div>
            <img src="https://example.com/headphones.jpg" width="800" height="800">
          `;
        }, 150);
        </script>
        </body></html>
        """
        let encoded = try #require(html.data(using: .utf8)?.base64EncodedString())
        let url = try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))

        let capture = try await RenderedPageCaptureLoader().load(url)

        #expect(capture.title == "Auriculares dinámicos")
        #expect(capture.priceCents == 1_995)
        #expect(capture.currency == "EUR")
        #expect(capture.imageURL?.absoluteString == "https://example.com/headphones.jpg")
    }

    @Test @MainActor func capturesNextJSHydrationWhenProductIsNotInTheDOM() async throws {
        let html = """
        <html><head><script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"product":{
          "_type":"product",
          "id":"70010000130793",
          "name":"The Legend of Zelda: Ocarina of Time",
          "price":{"value":59.99,"currencyCode":"EUR"},
          "primaryCategoryId":"Games",
          "imageGroups":[{"images":[{"link":"https://assets.nintendo.eu/ocarina.jpg"}]}]
        }}}}
        </script></head><body></body></html>
        """
        let encoded = try #require(html.data(using: .utf8)?.base64EncodedString())
        let url = try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))

        let capture = try await RenderedPageCaptureLoader().load(url)

        #expect(capture.title == "The Legend of Zelda: Ocarina of Time")
        #expect(capture.priceCents == 5_999)
        #expect(capture.currency == "EUR")
        #expect(capture.category == "Games")
        #expect(capture.imageURL?.absoluteString == "https://assets.nintendo.eu/ocarina.jpg")
    }

    @Test @MainActor func currentPriceSemanticWinsOverAnEarlierSecondaryPrice() async throws {
        let html = """
        <html lang="es"><body><main>
          <h1>Producto con varias ofertas</h1>
          <div class="price-to-pay">5,49 €</div>
          <div class="priceToPay">6,99 €</div>
        </main></body></html>
        """
        let encoded = try #require(html.data(using: .utf8)?.base64EncodedString())
        let url = try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))

        let capture = try await RenderedPageCaptureLoader().load(url)

        #expect(capture.priceCents == 699)
        #expect(capture.currency == "EUR")
    }
}
