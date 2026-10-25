import Foundation
import Testing
@testable import PriceTracker

private final class MockAmazonURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct AmazonConnectorTests {
    @Test func unboundMetadataKeepsLinkWithoutInventingPrice() async throws {
        MockAmazonURLProtocol.responseData = Data("""
        <html><head>
        <meta name="title" content="Producto Amazon real : Amazon.es: Electrónica">
        <meta name="description" content="Descripción Amazon real">
        <meta property="og:title" content="Amazon">
        <meta property="og:image" content="https://example.com/amazon-placeholder.jpg">
        <meta property="product:price:amount" content="25.50">
        <meta property="product:price:currency" content="EUR">
        </head><body>
        <img id="landingImage" data-old-hires="https://example.com/amazon-real.jpg">
        </body></html>
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAmazonURLProtocol.self]
        let connector = AmazonConnector(
            session: URLSession(configuration: configuration),
            rendersDynamicPages: false
        )
        let url = try #require(URL(string: "https://www.amazon.es/dp/B012345678"))

        let item = try await connector.resolve(url: url)

        #expect(item.store == .amazon)
        #expect(item.storeItemID == "B012345678")
        #expect(item.title == "Producto Amazon real")
        #expect(item.subtitle == "Descripción Amazon real")
        #expect(item.imageURL?.absoluteString == "https://example.com/amazon-real.jpg")
        #expect(item.priceCents == nil) // unbound meta is not a verified product offer
        #expect(item.storeGenre == "Electrónica")
        #expect(Store.refreshableStores.contains(.amazon))
    }

    @Test func legacyCapturePriceIsNotTrustedWithoutEvidence() async throws {
        MockAmazonURLProtocol.responseData = Data("""
        <html><head>
        <meta name="title" content="Producto Amazon real : Amazon.es: Electrónica">
        <meta property="product:price:amount" content="5.49">
        <meta property="product:price:currency" content="EUR">
        </head></html>
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAmazonURLProtocol.self]
        let connector = AmazonConnector(
            session: URLSession(configuration: configuration),
            rendersDynamicPages: false
        )
        let url = try #require(URL(string: "https://www.amazon.es/dp/B012345678"))
        let capture = SharedPageCapture(
            pageURLString: url.absoluteString,
            title: "Producto Amazon real",
            priceCents: 699,
            currency: "EUR"
        )

        let item = try await connector.resolve(url: url, pageCapture: capture)

        #expect(item.priceCents == nil)
        #expect(item.currency == "EUR")
    }

    @Test func keepaUsesSpanishMarketplaceDomain() {
        let url = AmazonConnector.keepaURL(asin: "B07RXN1HGG", region: "ES")

        #expect(url.absoluteString == "https://keepa.com/#!product/9-B07RXN1HGG")
    }
}

extension AmazonConnectorTests {
    @Test func manualAndShareUseSameValidatedTotalAndRejectContradictions() async throws {
        let url = URL(string: "https://www.amazon.es/dp/B07VLJ5JDV")!
        let visible = "<input id='ASIN' value='B07VLJ5JDV'><span id='productTitle'>Cámara sintética</span><div id='corePrice_feature_div'><span class='a-price'><span class='a-offscreen'>1.090,99 €</span></span></div>"
        let structured = "<title>Cámara sintética</title><script type='application/ld+json'>{\"@type\":\"Product\",\"sku\":\"B07VLJ5JDV\",\"offers\":{\"price\":\"1090.99\",\"priceCurrency\":\"EUR\"}}</script>"
        MockAmazonURLProtocol.responseData = Data(structured.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAmazonURLProtocol.self]
        let connector = AmazonConnector(session: URLSession(configuration: configuration), rendersDynamicPages: false)
        let manual = try await connector.resolve(url: url)
        #expect(manual.priceCents == 109099)
        let capture = try #require(SharedPageCapture(propertyList: ["pageURL":url.absoluteString,
            "title":"Cámara sintética", "priceCents":1239, "currency":"USD", "amazonPriceHTML":visible]))
        let shared = try await connector.resolve(url: url, pageCapture: capture)
        #expect(shared.priceCents == manual.priceCents && shared.currency == "EUR")
        let item = Item(resolved: shared)
        #expect(item.priceCurrentCents == 109099 && item.priceAtAddCents == 109099 && item.priceLowCents == 109099)
        for invalid in [visible.replacingOccurrences(of: "1.090,99 €", with: "12,39 € al mes"),
                        visible.replacingOccurrences(of: "1.090,99 €", with: "12,39 €"),
                        visible.replacingOccurrences(of: "B07VLJ5JDV", with: "B000000001")] {
            var bad = capture; bad.amazonPriceHTML = invalid
            let saved = Item(resolved: try await connector.resolve(url: url, pageCapture: bad))
            #expect(saved.priceCurrentCents == nil && saved.priceLowCents == nil && saved.priceAtAddCents == nil)
            #expect(saved.canonicalURL == url && saved.lastSuccessAt == nil)
        }
    }
}
