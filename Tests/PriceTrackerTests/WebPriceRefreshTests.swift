import Foundation
import Testing
@testable import PriceTracker

private final class WebFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var html = ""
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html", "Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor WebFixtureStore: PriceHistoryStoring {
    var items: [Item]
    var history: [PriceObservation] = []
    init(_ item: Item) { items = [item] }
    func loadAll() -> [Item] { items }
    func save(_ values: [Item]) { items = values }
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        let stored = try await upsert(item); history.append(observation); return stored
    }
    func observations(for identityKey: String) -> [PriceObservation] { history }
}
private actor WebFixtureAlerts: AlertStoring {
    var values: [PriceAlert] = []
    func loadAll() -> [PriceAlert] { values }
    func save(_ values: [PriceAlert]) { self.values = values }
}

@Suite(.serialized)
struct WebPriceRefreshTests {
    private func session(html: String, status: Int = 200) -> URLSession {
        WebFixtureProtocol.html = html; WebFixtureProtocol.status = status; WebFixtureProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func item(_ store: Store = .generic) -> Item {
        let url = store == .amazon ? "https://www.amazon.es/dp/B012345678" : "https://shop.example/product"
        return Item(store: store, storeItemID: store == .amazon ? "B012345678" : url, canonicalURL: URL(string: url)!, title: "Cámara Demo", priceCurrentCents: 1999, priceAtAddCents: 2999, priceLowCents: 1999, lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private let html = """
    <script type="application/ld+json">{"@type":"Product","name":"Cámara Demo","url":"https://shop.example/product","offers":{"@type":"Offer","price":"19.99","priceCurrency":"EUR"}}</script>
    """

    @Test func realGenericConnectorAndCoordinatorRefreshEqualPriceAndHistory() async throws {
        let original = item(), store = WebFixtureStore(item()), fresh = Date(timeIntervalSince1970: 1_701_209_600)
        let connector = GenericStoreConnector(session: session(html: html), rendersDynamicPages: false)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: WebFixtureAlerts(), connectorToFetch: { _ in connector }, now: { fresh })
        let summary = try await coordinator.refreshCatalog()
        let stored = try #require(await store.loadAll().first)
        #expect(summary.checked == 1 && summary.failed == 0 && summary.skipped == 0)
        #expect(stored.priceCurrentCents == original.priceCurrentCents && stored.lastSuccessAt == fresh)
        #expect(await store.history.map(\.checkedAt) == [fresh])
        let request = try #require(WebFixtureProtocol.requests.first)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func realAmazonConnectorRefreshesSelectedASIN() async throws {
        let html = """
        <input id="ASIN" value="B012345678"><span id="productTitle">Cámara Demo</span>
        <div id="corePrice_feature_div"><span class="a-price"><span class="a-offscreen">18,99 €</span></span></div>
        """
        let value = item(.amazon), store = WebFixtureStore(item(.amazon)), fresh = Date(timeIntervalSince1970: 1_701_209_600)
        let connector = AmazonConnector(session: session(html: html), rendersDynamicPages: false)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: WebFixtureAlerts(), connectorToFetch: { _ in connector }, now: { fresh })
        let summary = try await coordinator.refreshCatalog()
        #expect(summary.failed == 0 && summary.checked == 1 && summary.dropped == 1)
        #expect(await store.loadAll().first?.lastSuccessAt == fresh)
        #expect(await store.loadAll().first?.priceCurrentCents == 1899)
        #expect(value.lastSuccessAt != fresh)
    }

    @Test func blockedAmbiguousAndCurrencyFailuresPreservePriceSuccessAndHistory() async throws {
        for body in ["<title>Robot Check</title>" + html, html.replacingOccurrences(of: "EUR", with: "USD"), "<div id='app'>Dynamic product</div>"] {
            let original = item(), store = WebFixtureStore(item()), fresh = Date(timeIntervalSince1970: 1_701_209_600)
            let connector = GenericStoreConnector(session: session(html: body), rendersDynamicPages: false)
            let coordinator = RefreshCoordinator(itemStore: store, alertStore: WebFixtureAlerts(), connectorToFetch: { _ in connector }, now: { fresh })
            let summary = try await coordinator.refreshCatalog()
            let stored = try #require(await store.loadAll().first)
            #expect(summary.failed == 1)
            #expect(stored.priceCurrentCents == original.priceCurrentCents && stored.lastSuccessAt == original.lastSuccessAt)
            #expect(stored.lastCheckedAt == fresh && stored.lastError != nil)
            #expect(await store.history.isEmpty)
        }
    }

    @Test func rateLimitStopsFurtherRequestsAndCancellationDoesNotFetch() async {
        let loader = WebPriceLoader(session: session(html: "Too many", status: 429), throttle: WebPriceThrottle(interval: 0))
        await #expect(throws: (any Error).self) { try await loader.fetch(item()) }
        await #expect(throws: (any Error).self) { try await loader.fetch(item()) }
        #expect(WebFixtureProtocol.requests.count == 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.fetch(item())
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(WebFixtureProtocol.requests.count == 1)
    }
    @Test func newlyAddedUnpricedWebItemGetsItsFirstVerifiedObservation() async throws {
        var original = item()
        original.priceCurrentCents = nil; original.lastSuccessAt = nil; original.priceLowCents = nil
        let store = WebFixtureStore(original), fresh = Date(timeIntervalSince1970: 1_701_209_600)
        let connector = GenericStoreConnector(session: session(html: html), rendersDynamicPages: false)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: WebFixtureAlerts(), connectorToFetch: { _ in connector }, now: { fresh })
        let result = await coordinator.refreshResult(id: original.id)
        #expect(result.error == nil && result.didPersist)
        #expect(await store.loadAll().first?.priceCurrentCents == 1999)
        #expect(await store.loadAll().first?.lastSuccessAt == fresh)
        #expect(await store.history.count == 1)
    }

}
