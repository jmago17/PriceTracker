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

// The URLProtocol fixture is shared mutable state; tests must not overwrite
// another in-flight request’s response or HTTP status.
@Suite(.serialized)
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
        // Actual decoded HTTP 400 body captured from country=ESP on 2026-10-07.
        MockLookupURLProtocol.responseData = Data(#"{"errorMessage":"Invalid value(s) for key(s): [country]","queryParameters":{"country":"ISO-2A country code"}}"#.utf8)
        MockLookupURLProtocol.statusCode = 400
        defer { MockLookupURLProtocol.statusCode = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let url = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))

        do {
            _ = try await connector.resolve(url: url)
            Issue.record("Expected HTTP 400 to fail before decoding")
        } catch ConnectorError.network(let message) {
            #expect(message.hasPrefix("iTunes devolvió HTTP 400 para country=ES"))
            #expect(message.contains("HTTP=400"))
            #expect(message.contains("id=425073498&country=ES"))
        } catch {
            Issue.record("Expected a network error, received: \(error)")
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

extension ITunesConnectorTests {
    @Test(arguments: ["US", "USA", "ES", "ESP"])
    func americanStorefrontOverridesPersistedRegionWhenFetching(region: String) async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"trackName":"Procreate","currency":"USD","price":12.99}]}"#.utf8)
        MockLookupURLProtocol.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { "USA" })
        )
        let item = Item(store: .appStore, storeItemID: "425073498", region: region,
                        currency: "EUR", canonicalURL: URL(string: "https://apps.apple.com/es/app/procreate/id425073498")!, title: "Procreate")
        let result = try await connector.fetch(item)
        let request = try #require(MockLookupURLProtocol.requestedURLs.last)
        let country = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value
        #expect(country == "US")
        #expect(result.currency == "USD")
        #expect(result.priceCents == 1299)
    }

    @Test func unavailableStorefrontUsesPersistedUSAWhenFetching() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"resultCount":1,"results":[{"trackId":425073498,"currency":"USD","price":12.99}]}"#.utf8)
        MockLookupURLProtocol.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { nil })
        )
        let item = Item(store: .appStore, storeItemID: "425073498", region: "USA",
                        currency: "USD", canonicalURL: URL(string: "https://apps.apple.com/es/app/procreate/id425073498")!, title: "Procreate")
        let result = try await connector.fetch(item)
        let request = try #require(MockLookupURLProtocol.requestedURLs.last)
        let country = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value
        #expect(country == "US")
        #expect(result.currency == "USD")
    }
}

extension ITunesConnectorTests {
    @Test(arguments: ["missingCount", "nullResults", "nullResult", "badPrice", "invalidJSON"])
    func decodingFailureIncludesSafeRequestAndSchemaPath(failure: String) async throws {
        let payload: String
        let expected: String
        switch failure {
        case "missingCount":
            payload = #"{"errorMessage":"PRIVATE_BODY_SENTINEL"}"#
            expected = "keyNotFound path=$.resultCount"
        case "nullResults":
            payload = #"{"resultCount":1,"results":null}"#
            expected = "valueNotFound"
        case "nullResult":
            payload = #"{"resultCount":1,"results":[null]}"#
            expected = "valueNotFound"
        case "badPrice":
            payload = #"{"resultCount":1,"results":[{"trackId":425073498,"price":"PRIVATE_BODY_SENTINEL"}]}"#
            expected = "typeMismatch expected=Double path=$.results[0].price"
        default:
            payload = "PRIVATE_BODY_SENTINEL"
            expected = "dataCorrupted path=$"
        }
        MockLookupURLProtocol.responseData = Data(payload.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { "USA" })
        )
        let item = Item(store: .appStore, storeItemID: "425073498", region: "ES", currency: "EUR",
                        canonicalURL: URL(string: "https://apps.apple.com/es/app/id425073498?private=CANONICAL_SENTINEL")!, title: "PRIVATE_TITLE_SENTINEL")
        do {
            _ = try await connector.fetch(item)
            Issue.record("Expected a schema failure")
        } catch ConnectorError.decoding(let message) {
            #expect(message.contains("GET https://itunes.apple.com/lookup?id=425073498&country=US"))
            #expect(message.contains("HTTP=200; bytes=\(payload.utf8.count)"))
            #expect(message.contains(expected))
            if failure == "nullResults" { #expect(message.contains("path=$.results")) }
            if failure == "nullResult" { #expect(message.contains("path=$.results[0]")) }
            #expect(!message.contains("SENTINEL"))
        } catch {
            Issue.record("Expected decoding diagnostic, received: \(error)")
        }
    }

    @Test func diagnosticRedactsNonNumericStoredIdentifiers() async throws {
        MockLookupURLProtocol.responseData = Data(#"{"errorMessage":"BODY_SENTINEL"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLookupURLProtocol.self]
        let connector = ITunesConnector(
            session: URLSession(configuration: configuration),
            storefrontRegionProvider: AppleStorefrontRegionProvider(resolver: { "USA" })
        )
        let item = Item(store: .appStore, storeItemID: "PRIVATE_ID_SENTINEL", region: "USA", currency: "USD",
                        canonicalURL: URL(string: "https://apps.apple.com/us/app/id425073498")!, title: "Probe")
        do {
            _ = try await connector.fetch(item)
            Issue.record("Expected a schema failure")
        } catch ConnectorError.decoding(let message) {
            #expect(message.contains("id=redacted&country=US"))
            #expect(!message.contains("SENTINEL"))
        } catch {
            Issue.record("Expected decoding diagnostic, received: \(error)")
        }
    }
}
