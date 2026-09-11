import Foundation
import Testing
@testable import PriceTracker

private final class MockLookupURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
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
        let connector = ITunesConnector(session: URLSession(configuration: configuration))
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
        let connector = ITunesConnector(session: URLSession(configuration: configuration))
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
        let connector = ITunesConnector(session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://apps.apple.com/es/app/procreate/id425073498"))

        await #expect(throws: ConnectorError.self) {
            try await connector.resolve(url: url)
        }
    }
}
