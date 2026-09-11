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

struct AmazonConnectorTests {
    @Test func extractsMetadataOnceButRemainsNonRefreshable() async throws {
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
        #expect(item.priceCents == 2_550)
        #expect(item.storeGenre == "Electrónica")
        #expect(!Store.refreshableStores.contains(.amazon))
    }

    @Test func renderedVisiblePriceOverridesAmbiguousStructuredPrice() async throws {
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

        #expect(item.priceCents == 699)
        #expect(item.currency == "EUR")
    }

    @Test func keepaUsesSpanishMarketplaceDomain() {
        let url = AmazonConnector.keepaURL(asin: "B07RXN1HGG", region: "ES")

        #expect(url.absoluteString == "https://keepa.com/#!product/9-B07RXN1HGG")
    }
}
