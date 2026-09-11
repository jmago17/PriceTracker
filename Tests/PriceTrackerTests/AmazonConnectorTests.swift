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
        <meta property="og:title" content="Producto Amazon">
        <meta property="og:image" content="https://example.com/amazon.jpg">
        <meta property="product:price:amount" content="25.50">
        <meta property="product:price:currency" content="EUR">
        </head></html>
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAmazonURLProtocol.self]
        let connector = AmazonConnector(session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://www.amazon.es/dp/B012345678"))

        let item = try await connector.resolve(url: url)

        #expect(item.store == .amazon)
        #expect(item.storeItemID == "B012345678")
        #expect(item.title == "Producto Amazon")
        #expect(item.priceCents == 2_550)
        #expect(!Store.refreshableStores.contains(.amazon))
    }
}
