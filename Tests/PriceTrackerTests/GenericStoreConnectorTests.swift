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

    @Test func playStationJSONLDExtractsCompleteProduct() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head>
        <script id="mfe-jsonld-tags" type="application/ld+json">
        {
          "@context": "http://schema.org",
          "@type": "Product",
          "name": "DEATH STRANDING 2: ON THE BEACH",
          "category": "Juego completo",
          "description": "SHOULD WE HAVE CONNECTED",
          "sku": "JP9000-PPSA02015_00-DS2OTB0000000001",
          "image": "https://image.api.playstation.com/death-stranding-2.png",
          "offers": {"@type": "Offer", "price": 49.59, "priceCurrency": "EUR"}
        }
        </script>
        </head></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://store.playstation.com/es-es/product/JP9000-PPSA02015_00-DS2OTB0000000001"))

        let item = try await connector.resolve(url: url)

        #expect(item.title == "DEATH STRANDING 2: ON THE BEACH")
        #expect(item.subtitle == "SHOULD WE HAVE CONNECTED")
        #expect(item.priceCents == 4_959)
        #expect(item.currency == "EUR")
        #expect(item.imageURL?.absoluteString == "https://image.api.playstation.com/death-stranding-2.png")
        #expect(item.storeGenre == "Juego completo")
    }

    @Test func imageObjectArrayUsesItsContentURL() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head>
        <script type="application/ld+json">
        {
          "@type": "Product",
          "name": "TIMMERFLOTTE Sensor temperatura/humedad",
          "category": "Sensores inteligentes",
          "description": "Sensor compatible con Matter",
          "image": [{"@type": "ImageObject", "contentUrl": "https://www.ikea.com/timmerflotte.jpg"}],
          "offers": {"@type": "Offer", "price": "7.99", "priceCurrency": "EUR"}
        }
        </script>
        </head></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://www.ikea.com/es/es/p/timmerflotte-30597606/"))

        let item = try await connector.resolve(url: url)

        #expect(item.imageURL?.absoluteString == "https://www.ikea.com/timmerflotte.jpg")
        #expect(item.priceCents == 799)
        #expect(item.storeGenre == "Sensores inteligentes")
    }

    @Test func renderedCaptureCompletesDynamicStoreMetadata() async throws {
        MockGenericStoreURLProtocol.responseData = Data("""
        <html><head><title>AliExpress</title></head></html>
        """.utf8)
        let connector = makeConnector()
        let url = try #require(URL(string: "https://es.aliexpress.com/item/100500000000.html"))
        let capture = SharedPageCapture(
            pageURLString: url.absoluteString,
            title: "Auriculares inalámbricos",
            description: "Bluetooth con cancelación de ruido",
            imageURLString: "https://ae01.alicdn.com/product.jpg",
            priceCents: 2_499,
            currency: "EUR",
            category: "Electrónica"
        )

        let item = try await connector.resolve(url: url, pageCapture: capture)

        #expect(item.title == "Auriculares inalámbricos")
        #expect(item.subtitle == "Bluetooth con cancelación de ruido")
        #expect(item.imageURL?.absoluteString == "https://ae01.alicdn.com/product.jpg")
        #expect(item.priceCents == 2_499)
        #expect(item.currency == "EUR")
        #expect(item.storeGenre == "Electrónica")
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
        return GenericStoreConnector(
            session: URLSession(configuration: configuration),
            rendersDynamicPages: false
        )
    }
}
