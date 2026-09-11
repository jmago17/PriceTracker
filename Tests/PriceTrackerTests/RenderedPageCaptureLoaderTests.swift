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
}
