import Foundation
import Testing
@testable import PriceTracker

private final class MockAppleStoreURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct AppleStoreConnectorTests {
    @Test func configuredWatchUsesExactOfferAndSKU() async throws {
        MockAppleStoreURLProtocol.responseData = htmlData(
            #"{"@context":"https://schema.org","@type":"Product","name":"Apple Watch Series 12 (GPS) - 46 mm","url":"https://www.apple.com/es/shop/buy-watch/apple-watch/configured-watch","offers":[{"@type":"Offer","priceCurrency":"EUR","price":499.00,"sku":"Z0YQ+MJFV4QL/A+MKTQ4ZM/A"}],"image":"https://example.com/watch.jpg"}"#
        )
        let connector = makeConnector()
        let url = try #require(URL(string: "https://www.apple.com/es/shop/buy-watch/apple-watch/configured-watch"))

        #expect(connector.canResolve(url: url))
        let item = try await connector.resolve(url: url)

        #expect(item.store == .appleStore)
        #expect(item.storeItemID == "Z0YQ+MJFV4QL/A+MKTQ4ZM/A")
        #expect(item.region == "ES")
        #expect(item.currency == "EUR")
        #expect(item.priceCents == 49_900)
        #expect(item.subtitle == "Apple Store")
    }

    @Test func watchFamilyPageKeepsLowPriceAsFromPrice() async throws {
        MockAppleStoreURLProtocol.responseData = htmlData(
            #"{"@context":"https://schema.org","@type":"Product","name":"Apple Watch Series 12","url":"https://www.apple.com/es/shop/buy-watch/apple-watch","offers":[{"@type":"AggregateOffer","lowPrice":449.00,"highPrice":1399.00,"priceCurrency":"EUR"}]}"#
        )
        let connector = makeConnector()
        let url = try #require(URL(string: "https://www.apple.com/es/shop/buy-watch/apple-watch"))

        let item = try await connector.resolve(url: url)

        #expect(item.store == .appleStore)
        #expect(item.priceCents == 44_900)
        #expect(item.subtitle == "Precio desde")
    }

    @Test func appleMarketingPageIsNotClaimedAsAStoreProduct() throws {
        let connector = makeConnector()
        let url = try #require(URL(string: "https://www.apple.com/es/watch/"))

        #expect(!connector.canResolve(url: url))
    }

    private func makeConnector() -> AppleStoreConnector {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAppleStoreURLProtocol.self]
        return AppleStoreConnector(session: URLSession(configuration: configuration))
    }

    private func htmlData(_ json: String) -> Data {
        Data("""
        <!doctype html><html><head>
        <script type="application/ld+json">\(json)</script>
        </head><body></body></html>
        """.utf8)
    }
}
