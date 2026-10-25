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

// Synthetic HTML rendered by real WebKit + the real bundle resource. This is
// NOT a live Amazon page or a reconstruction of the historical 12.39 incident.
import WebKit

@MainActor
private final class AmazonFixtureNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?
    func load(_ html: String, webView: WKWebView, baseURL: URL) async throws {
        webView.navigationDelegate = self
        defer { timeout?.cancel(); webView.stopLoading(); webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.finish(URLError(.timedOut))
            }
        }
    }
    private func finish(_ error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }
}

extension RenderedPageCaptureLoaderTests {
    @Test @MainActor func amazonDOMCaptureAndSwiftValidationShareTheSameContract() async throws {
        let url = URL(string: "https://www.amazon.es/dp/B07VLJ5JDV")!
        let scriptURL = try #require(Bundle.main.url(forResource: "PageCapture", withExtension: "js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let navigation = AmazonFixtureNavigation()
        for amount in ["1.090,99 €", "12,39 € al mes", "12,39 €–1.090,99 €"] {
            let html = """
            <html><head><title>Cámara sintética</title><style>.fixture-hidden {display:none}</style></head><body>
            <input id=ASIN type=hidden value=B07VLJ5JDV><span id=productTitle>Cámara sintética</span>
            <meta itemprop=price content=12.39><meta itemprop=priceCurrency content=USD>
            <div id=corePrice_feature_div>
              <span class='a-price'><span class='a-offscreen'>\(amount)</span><span aria-hidden=true>1090<small>99</small>€</span></span>
              <span class='a-price fixture-hidden'><span class=a-offscreen>1,23 €</span></span>
              <input type=hidden name=unrelatedToken value=DO-NOT-CAPTURE>
            </div>
            <div id=recommendations><span class=a-price>12,39 €</span></div>
            </body></html>
            """
            try await navigation.load(html, webView: webView, baseURL: url)
            _ = try await webView.evaluateJavaScript(script)
            let json = try #require(try await webView.evaluateJavaScript("JSON.stringify(capturePage())") as? String)
            let dictionary = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let capture = try #require(SharedPageCapture(propertyList: dictionary))
            #expect(capture.priceCents == nil) // no unvalidated amount crosses the Share boundary
            let evidence = try #require(capture.amazonPriceHTML)
            #expect(!evidence.contains("DO-NOT-CAPTURE") && !evidence.contains("1,23"))
            let parsed = try? WebPriceParser.amazonAddPrice(data: Data(evidence.utf8), url: url, title: "Cámara sintética", size: nil, color: nil)
            #expect(parsed?.priceCents == (amount == "1.090,99 €" ? 109099 : nil))
        }
    }
}
