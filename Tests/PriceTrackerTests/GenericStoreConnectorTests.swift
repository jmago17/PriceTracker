import Foundation
import Testing
@testable import PriceTracker

private final class MockGenericStoreURLProtocol: URLProtocol, @unchecked Sendable {
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

struct GenericStoreConnectorTests {
    @Test func arbitraryStoreExtractsOpenGraphMetadataOnce() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head>
        <meta property="og:title" content="Cafetera Demo &amp; Accesorios">
        <meta property="og:description" content="Descripción del producto">
        <meta property="og:image" content="https://example.com/product.jpg">
        <meta property="product:price:amount" content="129.95">
        <meta property="product:price:currency" content="EUR">
        <link rel="canonical" href="https://tienda.example/es/productos/cafetera">
        </head></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://tienda.example/es/productos/cafetera?ref=share"))

        #expect(connector.canResolve(url: url))
        let item = try await connector.resolve(url: url)

        #expect(item.store == .generic)
        #expect(item.title == "Cafetera Demo & Accesorios")
        #expect(item.subtitle == "Descripción del producto")
        #expect(item.priceCents == 12_995)
        #expect(item.currency == "EUR")
        #expect(item.canonicalURL.absoluteString == "https://tienda.example/es/productos/cafetera")
    }

    @Test func arbitraryStoreWithoutPriceStillSavesMetadata() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head><title>Producto sin precio</title></head><body></body></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://otra-tienda.example/producto/123"))

        let item = try await connector.resolve(url: url)

        #expect(item.title == "Producto sin precio")
        #expect(item.priceCents == nil)
        #expect(!Store.refreshableStores.contains(item.store))
    }

    @Test func nonWebURLIsRejected() throws {
        let connector = makeConnector()
        let url = try #require(URL(string: "file:///tmp/product.html"))

        #expect(!connector.canResolve(url: url))
    }

    @Test func priceWithoutCurrencyIsNotInvented() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head>
        <meta property="og:title" content="Precio sin moneda">
        <meta property="product:price:amount" content="10.00">
        </head></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://tienda.example/producto"))

        let item = try await connector.resolve(url: url)

        #expect(item.priceCents == nil)
    }

    private func makeConnector() -> GenericStoreConnector {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGenericStoreURLProtocol.self]
        return GenericStoreConnector(session: URLSession(configuration: configuration))
    }
}
