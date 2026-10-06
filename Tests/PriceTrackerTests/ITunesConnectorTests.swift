import Foundation
import Testing
@testable import PriceTracker

private final class MockLookupURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200
    /// Records the exact URLs sent to iTunes, which is where the alpha-3 vs
    /// alpha-2 country regression actually showed up.
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.requestedURLs.append(url) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ITunesConnectorTests {
    @Test func freeUSAppIsResolvedAtZeroPrice() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":1053012308,"trackName":"Clash Royale","sellerName":"Supercell","currency":"USD","price":0.0,"formattedPrice":"Free","primaryGenreName":"Games","artworkUrl100":"https://example.com/icon.png","trackViewUrl":"https://apps.apple.com/us/app/clash-royale/id1053012308"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let url = try #require(URL(string: "https://apps.apple.com/us/app/clash-royale/id1053012308"))

        #expect(connector.canResolve(url: url))
        let item = try await connector.resolve(url: url)
        #expect(item.store == .appStore)
        #expect(item.storeItemID == "1053012308")
        #expect(item.region == "US")
        #expect(item.currency == "USD")
        #expect(item.title == "Clash Royale")
        #expect(item.priceCents == 0)
    }

    @Test func paidAppUsesSoftwarePrice() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","sellerName":"Savage Interactive Pty Ltd","currency":"EUR","price":14.99,"formattedPrice":"14,99 €","primaryGenreName":"Graphics & Design","trackViewUrl":"https://apps.apple.com/es/app/procreate/id425073498"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let url = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))

        let item = try await connector.resolve(url: url)

        #expect(item.region == "ES")
        #expect(item.currency == "EUR")
        #expect(item.priceCents == 1499)
    }

    @Test func missingNumericPriceIsNotTreatedAsFree() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"EUR","formattedPrice":"14,99 €"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let url = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))

        await #expect(throws: ConnectorError.self) {
            try await connector.resolve(url: url)
        }
    }
}


extension ITunesConnectorTests {
    @Test func signedInStorefrontOverridesCountryEmbeddedInURL() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"USD","price":12.99,"trackViewUrl":"https://apps.apple.com/us/app/procreate/id425073498"}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { "USA" })
        )

        let item = try await connector.resolve(url: #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498")))

        // "USA" is what StoreKit reports, but the region we store and send must
        // be alpha-2. Asserting "USA" here is what let the HTTP 400 through.
        #expect(item.region == "US")
        #expect(item.currency == "USD")
        #expect(item.priceCents == 1299)
    }

    @Test func lookupRequestAlwaysUsesAlphaTwoCountryCode() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"USD","price":12.99}]}"#.utf8)
        MockLookupURLProtocol.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { "USA" })
        )

        _ = try await connector.resolve(url: #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498")))

        let query = try #require(MockLookupURLProtocol.requestedURLs.last?.query)
        #expect(query.contains("country=US"))
        #expect(!query.contains("country=USA"))
    }

    @Test func legacyAlphaThreeRegionOnDiskIsNormalizedWhenFetching() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"EUR","price":14.99}]}"#.utf8)
        MockLookupURLProtocol.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        // An item written by the previous build still carries "ESP" on disk.
        let canonical = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))
        let item = Item(
            store: .appStore,
            storeItemID: "425073498",
            region: "ESP",
            currency: "EUR",
            canonicalURL: canonical,
            title: "Procreate"
        )

        let result = try await connector.fetch(item)

        let query = try #require(MockLookupURLProtocol.requestedURLs.last?.query)
        #expect(query.contains("country=ES"))
        #expect(result.priceCents == 1499)
    }

    @Test func rejectedStorefrontSurfacesAsNetworkErrorNotDecodingError() async throws {
        // The real endpoint answers 400 with a non-JSON body.
        MockLookupURLProtocol.responseData = Data([0x1f, 0x8b, 0x08, 0x00])
        MockLookupURLProtocol.statusCode = 400
        defer { MockLookupURLProtocol.statusCode = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let url = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))

        await #expect(throws: ConnectorError.self) {
            _ = try await connector.resolve(url: url)
        }
    }

    @Test func fallsBackToURLCountryWhenStorefrontIsUnavailable() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"EUR","price":14.99}]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )

        let item = try await connector.resolve(url: #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498")))
        #expect(item.region == "ES")
        #expect(item.currency == "EUR")
    }
}
