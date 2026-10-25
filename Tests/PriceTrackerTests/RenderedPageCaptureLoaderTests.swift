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

// Always fail public metadata loading: these tests must exercise captured DOM
// evidence alone, without URLSession traffic or a second source masking R1.
private final class OfflineAmazonFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

extension RenderedPageCaptureLoaderTests {
    // R1 follow-up: added locally, NOT yet compiled/executed on Mac.
    @Test @MainActor func amazonWrapperContextSurvivesJavaScriptThroughOfflineResolveAndItem() async throws {
        let url = URL(string: "https://www.amazon.es/dp/B07VLJ5JDV")!
        let scriptURL = try #require(Bundle.main.url(forResource: "PageCapture", withExtension: "js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let navigation = AmazonFixtureNavigation()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [OfflineAmazonFixtureProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let connector = AmazonConnector(session: session, rendersDynamicPages: false)
        let manual = Item(resolved: try await connector.resolve(url: url))
        #expect(manual.canonicalURL == url && manual.priceCurrentCents == nil && manual.priceAtAddCents == nil && manual.priceLowCents == nil && manual.lastSuccessAt == nil)
        let total = "<span class='a-price'><span class='a-offscreen'>12,39 €</span></span>"
        let cases: [(name: String, body: String, expected: Int?)] = [
            ("button aria financing", "<button aria-label='3 pagos al mes'>i</button>" + total, nil),
            ("button title financing", "<button title='3 pagos al mes'>i</button>" + total, nil),
            ("link other ASIN", "<a data-asin='B000000001' class='recommended-accessory' href='https://example.invalid/PRIVATE-HREF'>" + total + "</a>", nil),
            ("arbitrary article other ASIN", "<article data-asin='B000000001'>" + total + "</article>", nil),
            ("arbitrary definition title", "<dl><dd title='3 pagos al mes'>i</dd></dl>" + total, nil),
            ("arbitrary custom aria", "<x-context aria-label='3 pagos al mes'>i</x-context>" + total, nil),
            ("legitimate small total", "<article title='Precio total'>" + total + "</article>", 1239),
            ("safe attributes only", "<a href='https://example.invalid/PRIVATE-HREF' onclick='PRIVATE-EVENT' name='PRIVATE-NAME' value='PRIVATE-VALUE' title='Precio total'>" + total + "</a>", 1239),
            ("script and duplicates excluded", total + "<script>window.fixtureSecret = 'PRIVATE-SCRIPT';</script><article hidden>99,99 €</article><button aria-hidden='true'>88,88 €</button><input name='csrf' value='PRIVATE-INPUT'>", 1239)
        ]
        for fixture in cases {
            let html = """
            <html><head><title>Cámara sintética</title>
            <meta name="description" content="Metadatos sintéticos conservados">
            </head><body><input id="ASIN" type="hidden" value="B07VLJ5JDV">
            <span id="productTitle">Cámara sintética</span>
            <div id="corePrice_feature_div">\(fixture.body)</div></body></html>
            """
            // Both the original and the actual JS fragment must agree. No
            // hand-sanitized Swift fixture can stand in for this assertion.
            let original = try? WebPriceParser.amazonAddPrice(data: Data(html.utf8), url: url, title: "Cámara sintética", size: nil, color: nil)
            #expect(original?.priceCents == fixture.expected, "Original: \(fixture.name)")
            try await navigation.load(html, webView: webView, baseURL: url)
            _ = try await webView.evaluateJavaScript(script)
            let json = try #require(try await webView.evaluateJavaScript("JSON.stringify(capturePage())") as? String)
            let dictionary = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let capture = try #require(SharedPageCapture(propertyList: dictionary))
            #expect(capture.priceCents == nil)
            let evidence = try #require(capture.amazonPriceHTML)
            #expect(!evidence.contains("PRIVATE-") && !evidence.contains("99,99") && !evidence.contains("88,88"))
            let fragment = try? WebPriceParser.amazonAddPrice(data: Data(evidence.utf8), url: url, title: "Cámara sintética", size: nil, color: nil)
            #expect(fragment?.priceCents == original?.priceCents, "Fragment: \(fixture.name)")
            let resolved = try await connector.resolve(url: url, pageCapture: capture)
            #expect(resolved.title == "Cámara sintética" && resolved.subtitle == "Metadatos sintéticos conservados")
            #expect(resolved.storeItemID == "B07VLJ5JDV" && resolved.currency == "EUR")
            let saved = Item(resolved: resolved)
            #expect(saved.canonicalURL == url)
            #expect(saved.priceCurrentCents == fixture.expected && saved.priceAtAddCents == fixture.expected && saved.priceLowCents == fixture.expected, "Item: \(fixture.name)")
            if fixture.expected == nil { #expect(saved.lastSuccessAt == nil) }
        }
    }

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
