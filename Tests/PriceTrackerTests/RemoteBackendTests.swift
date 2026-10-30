import Foundation
import Testing
@testable import PriceTracker

// MARK: - Test doubles (no network, no real key)

private final class FakeTransport: PriceBucketTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var handler: Handler

    init(_ handler: @escaping Handler = { _ in (500, "{}") }) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    func respond(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let current = lock.withLock { () -> Handler in
            recorded.append(request)
            return handler
        }
        let (status, body) = try current(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class MemoryKeyStore: KeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() throws -> String? { lock.withLock { value } }
    func write(_ newValue: String?) throws { lock.withLock { value = newValue } }
}

private let testKey = "test-key-not-a-secret"

private func makeSettings(key: String? = testKey) -> PriceBucketSettings {
    PriceBucketSettings(defaults: UserDefaults(suiteName: "remote-tests-\(UUID().uuidString)")!, keyStore: MemoryKeyStore(key))
}

private func makeClient(_ transport: FakeTransport, settings: PriceBucketSettings? = nil) -> PriceBucketClient {
    let settings = settings ?? makeSettings()
    return PriceBucketClient(transport: transport, configuration: { try settings.configuration() })
}

private func makeRemote(_ transport: FakeTransport, key: String? = testKey) -> (RemoteItemStore, SQLiteItemStore) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PriceTrackerRemoteTests")
        .appendingPathComponent(UUID().uuidString)
    let cache = SQLiteItemStore(databaseURL: directory.appendingPathComponent("remote-cache.sqlite"))
    let settings = makeSettings(key: key)
    let remote = RemoteItemStore(cache: cache, client: makeClient(transport, settings: settings), settings: settings)
    return (remote, cache)
}

private func itemJSON(
    id: UUID = UUID(),
    store: String = "appStore",
    storeItemID: String = "100",
    status: String = "active",
    title: String = "Producto",
    price: Int? = 999,
    target: Int? = nil,
    nulls: Bool = false
) -> String {
    func number(_ value: Int?) -> String { value.map(String.init) ?? "null" }
    func text(_ value: String, _ present: Bool = true) -> String { nulls || !present ? "null" : "\"\(value)\"" }
    return """
    {
     "id": "\(id.uuidString)", "store": "\(store)", "storeItemID": "\(storeItemID)", "region": "ES", "currency": "EUR",
     "canonicalURL": "https://example.test/p/\(storeItemID)", "title": "\(title)",
     "subtitle": \(text("Sub")), "imageURL": \(text("https://example.test/img/\(id.uuidString)?s=abc")),
     "category": \(text("Electrónica")), "categorySource": "\(nulls ? "none" : "mapped")", "storeGenre": \(text("Genre")),
     "status": "\(status)",
     "priceCurrentCents": \(number(nulls ? nil : price)), "priceAtAddCents": \(number(nulls ? nil : 1200)),
     "priceReferenceCents": \(number(nulls ? nil : 1500)), "priceLowCents": \(number(nulls ? nil : 900)),
     "priceLowAt": \(text("2026-10-25T08:00:00Z")), "targetPriceCents": \(number(target)),
     "lastAlertedPriceCents": null, "onSaleUntil": null,
     "checkIntervalHours": 24, "lastCheckedAt": \(text("2026-10-30T08:01:10Z")), "lastSuccessAt": \(text("2026-10-30T08:01:10Z")),
     "consecutiveFailures": \(status == "stale" ? 3 : 0), "lastError": \(text("boom", status == "stale")),
     "externalIDs": {}, "tags": \(nulls ? "null" : "[\"foto\"]"), "notes": \(text("nota")), "summary": \(text("resumen")),
     "size": \(text("M")), "color": \(text("Plata")),
     "createdAt": "2026-10-25T10:34:31Z", "updatedAt": "2026-10-30T08:01:10Z"
    }
    """
}

private func itemsBody(serverTime: String, full: Bool, items: [String] = [], deleted: [UUID] = []) -> String {
    """
    {"serverTime": "\(serverTime)", "full": \(full), "items": [\(items.joined(separator: ","))],
     "deleted": [\(deleted.map { "\"\($0.uuidString)\"" }.joined(separator: ","))]}
    """
}

private func decodeItem(_ json: String) throws -> Item {
    try PriceBucketClient.decoder.decode(Item.self, from: Data(json.utf8))
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

// MARK: - Decoding

struct RemoteItemDecodingTests {
    @Test(arguments: ["active", "archived", "unavailable", "stale"], [false, true])
    func decodesEveryStatusWithAndWithoutNulls(status: String, nulls: Bool) throws {
        let id = UUID()
        let item = try decodeItem(itemJSON(id: id, status: status, nulls: nulls))
        #expect(item.id == id)
        #expect(item.status.rawValue == status)
        if nulls {
            #expect(item.priceCurrentCents == nil)
            #expect(item.subtitle == nil)
            #expect(item.imageURL == nil)
            #expect(item.category == nil)
            #expect(item.lastCheckedAt == nil)
            #expect(item.tags == nil)
            #expect(item.size == nil)
            #expect(item.isPendingFirstCheck)
        } else {
            #expect(item.priceCurrentCents == 999)
            #expect(item.tags == ["foto"])
            #expect(item.color == "Plata")
            #expect(item.lastSuccessAt == Date(timeIntervalSince1970: 1_793_347_270))
            #expect(!item.isPendingFirstCheck)
        }
    }

    @Test func decodesStoresAndCategorySources() throws {
        for store in ["appStore", "amazon", "generic"] {
            #expect(try decodeItem(itemJSON(store: store)).store.rawValue == store)
        }
    }

    @Test func decodesTheDocumentedItemsEnvelope() throws {
        let body = itemsBody(serverTime: "2026-10-30T16:20:00Z", full: true, items: [itemJSON()], deleted: [UUID()])
        let response = try PriceBucketClient.decoder.decode(ItemsResponse.self, from: Data(body.utf8))
        #expect(response.full && response.items.count == 1 && response.deleted.count == 1)
        #expect(response.serverTime == "2026-10-30T16:20:00Z")
    }

    @Test func historyPointsTolerateMissingOptionalFields() throws {
        let item = try decodeItem(itemJSON())
        let pointID = UUID()
        let json = "{\"id\":\"\(pointID.uuidString)\",\"checkedAt\":\"2026-10-30T08:00:00Z\",\"priceCents\":499}"
        let point = try PriceBucketClient.decoder.decode(RemoteObservation.self, from: Data(json.utf8))
        let observation = point.observation(for: item)
        #expect(observation.id == pointID && observation.itemID == item.id)
        #expect(observation.currency == "EUR" && !observation.isOnSale)
    }
}

// MARK: - Client

struct PriceBucketClientTests {
    @Test func sendsKeyHeaderAndNeverPutsItInTheURL() async throws {
        let transport = FakeTransport { _ in (200, "{\"ok\":true,\"version\":3,\"items\":39,\"serverTime\":\"2026-10-30T16:20:00Z\"}") }
        let me = try await makeClient(transport).me()
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-key") == testKey)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/me")
        #expect(request.url?.absoluteString.contains(testKey) == false)
        #expect(me.items == 39 && me.version == "3")
    }

    @Test func itemsUsesSinceOnlyWhenGiven() async throws {
        let transport = FakeTransport { _ in (200, itemsBody(serverTime: "2026-10-30T16:20:00Z", full: true)) }
        let client = makeClient(transport)
        _ = try await client.items()
        _ = try await client.items(since: "2026-10-30T16:20:00Z")
        let requests = transport.requests
        #expect(requests[0].url?.path == "/api/v1/items" && query(requests[0]).isEmpty)
        #expect(query(requests[1])["since"] == "2026-10-30T16:20:00Z")
    }

    @Test func routesAndMethods() async throws {
        let id = UUID()
        let item = itemJSON(id: id)
        let transport = FakeTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("DELETE", _): return (200, "{\"ok\":true,\"left\":1}")
            case (_, let path) where path.hasSuffix("/history"): return (200, "{\"observations\":[]}")
            case (_, let path) where path.hasSuffix("/refresh"): return (200, "{\"ok\":true,\"deferred\":true,\"why\":\"amazon\",\"item\":\(item)}")
            default: return (200, "{\"ok\":true,\"item\":\(item)}")
            }
        }
        let client = makeClient(transport)
        _ = try await client.addItem(url: URL(string: "https://example.test/x")!)
        _ = try await client.item(id: id)
        _ = try await client.patchItem(id: id, patch: ItemPatch(title: .set("Nuevo")))
        try await client.deleteItem(id: id)
        _ = try await client.history(id: id)
        let refreshed = try await client.refreshItem(id: id)
        #expect(refreshed.deferred && refreshed.why == "amazon")
        let seen = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(seen == [
            "POST /api/v1/items",
            "GET /api/v1/items/\(id.uuidString)",
            "PATCH /api/v1/items/\(id.uuidString)",
            "DELETE /api/v1/items/\(id.uuidString)",
            "GET /api/v1/items/\(id.uuidString)/history",
            "POST /api/v1/items/\(id.uuidString)/refresh",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-key") == testKey })
    }

    @Test func mapsStatusCodesToSpanishErrors() async throws {
        let transport = FakeTransport { _ in (401, "{}") }
        let client = makeClient(transport)
        await #expect(throws: PriceBucketError.unauthorized) { try await client.me() }

        transport.respond { _ in (422, "{\"ok\":false,\"error\":\"El enlace ya existe\"}") }
        await #expect(throws: PriceBucketError.validation("El enlace ya existe")) {
            try await client.addItem(url: URL(string: "https://example.test/x")!)
        }

        transport.respond { _ in (404, "{}") }
        await #expect(throws: PriceBucketError.notFound) { try await client.item(id: UUID()) }

        transport.respond { _ in (502, "{\"error\":\"timeout\"}") }
        await #expect(throws: PriceBucketError.storeUnreachable("timeout")) { try await client.refreshItem(id: UUID()) }

        transport.respond { _ in (503, "") }
        await #expect(throws: PriceBucketError.server(503)) { try await client.me() }

        transport.respond { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: PriceBucketError.offline) { try await client.me() }

        transport.respond { _ in (200, "not json") }
        await #expect(throws: PriceBucketError.invalidResponse) { try await client.me() }
    }

    @Test func errorsAreInSpanishAndExistingLinkIsRecognised() {
        #expect(PriceBucketError.unauthorized.localizedDescription.contains("clave"))
        #expect(PriceBucketError.offline.localizedDescription.contains("conexión"))
        #expect(PriceBucketError.validation("Ese enlace ya existe en el catálogo").isAlreadyExists)
        #expect(!PriceBucketError.validation("Enlace no válido").isAlreadyExists)
    }

    @Test func withoutKeyNoRequestIsMade() async {
        let transport = FakeTransport()
        let client = makeClient(transport, settings: makeSettings(key: nil))
        await #expect(throws: PriceBucketError.notConfigured) { try await client.me() }
        #expect(transport.requests.isEmpty)
    }

    @Test func patchSerialisesExplicitNullAndOmitsUntouchedFields() throws {
        let patch = ItemPatch(targetPriceCents: .clear)
        let object = try #require(JSONSerialization.jsonObject(with: try PriceBucketClient.encoder.encode(patch)) as? [String: Any])
        #expect(object.keys.sorted() == ["targetPriceCents"])
        #expect(object["targetPriceCents"] is NSNull)

        var full = ItemPatch()
        full.title = .set("T"); full.targetPriceCents = .set(4500); full.tags = .set(["a", "b"])
        full.status = .set(.archived); full.category = .set("Libros"); full.notes = .clear
        let data = try PriceBucketClient.encoder.encode(full)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["targetPriceCents"] as? Int == 4500)
        #expect(decoded["tags"] as? [String] == ["a", "b"])
        #expect(decoded["status"] as? String == "archived")
        #expect(decoded["notes"] is NSNull)
        #expect(decoded["price"] == nil)
    }

    @Test func diffOnlyContainsWhatTheServerStores() throws {
        let old = try decodeItem(itemJSON(target: 500))
        var new = old
        new.targetPriceCents = nil
        new.tags = ["x"]
        new.lastAlertedPriceCents = 1          // local-only: never sent
        new.priority = .high                    // local-only: never sent
        new.updatedAt = Date()
        let patch = ItemPatch.diff(from: old, to: new)
        #expect(patch.targetPriceCents == .clear)
        #expect(patch.tags == .set(["x"]))
        #expect(patch.title == .unchanged && patch.status == .unchanged)

        var local = old
        local.priority = .high
        #expect(ItemPatch.diff(from: old, to: local).isEmpty)

        var stale = old
        stale.status = .stale   // derived by the server, not settable
        #expect(ItemPatch.diff(from: old, to: stale).isEmpty)
        var paused = old
        paused.status = .archived
        #expect(ItemPatch.diff(from: old, to: paused).status == .set(.archived))
    }
}

// MARK: - Settings

struct PriceBucketSettingsTests {
    @Test func defaultsAndValidation() throws {
        let settings = makeSettings(key: nil)
        #expect(settings.baseURL == PriceBucketSettings.defaultBaseURL)
        #expect(!settings.isConfigured)
        try settings.setBaseURL("https://example.test/")
        #expect(settings.baseURL.absoluteString == "https://example.test")
        #expect(throws: PriceBucketError.self) { try settings.setBaseURL("http://insecure.test") }
        try settings.setBaseURL("")
        #expect(settings.baseURL == PriceBucketSettings.defaultBaseURL)
    }

    @Test func keyLivesOnlyInTheKeyStore() throws {
        let suite = "remote-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = MemoryKeyStore()
        let settings = PriceBucketSettings(defaults: defaults, keyStore: store)
        try settings.setAPIKey("  \(testKey) \n")
        #expect(settings.apiKey == testKey && settings.isConfigured)
        #expect(try store.read() == testKey)
        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!stored.contains { $0.contains(testKey) })
        try settings.setAPIKey("   ")
        #expect(!settings.isConfigured)
    }
}

// MARK: - RemoteItemStore

struct RemoteItemStoreTests {
    @Test func fullThenIncrementalSyncAppliesChangesAndDeletes() async throws {
        let a = UUID(), b = UUID(), c = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [
                itemJSON(id: a, storeItemID: "a", title: "A"), itemJSON(id: b, storeItemID: "b", title: "B"),
            ]))
        }
        let (remote, _) = makeRemote(transport)
        let first = try await remote.sync()
        #expect(first.full && first.received == 2)
        #expect(try await remote.loadAll().map(\.title).sorted() == ["A", "B"])
        #expect(query(transport.requests[0])["since"] == nil)

        transport.respond { _ in
            (200, itemsBody(serverTime: "2026-10-30T11:00:00Z", full: false, items: [
                itemJSON(id: a, storeItemID: "a", title: "A2"), itemJSON(id: c, storeItemID: "c", title: "C"),
            ], deleted: [b]))
        }
        let second = try await remote.sync()
        #expect(!second.full && second.deleted == 1)
        #expect(query(transport.requests[1])["since"] == "2026-10-30T10:00:00Z")
        let titles = try await remote.loadAll().map(\.title).sorted()
        #expect(titles == ["A2", "C"])
        #expect(try await remote.loadAll().first { $0.storeItemID == "a" }?.id == a)

        _ = try await remote.sync()
        #expect(query(transport.requests[2])["since"] == "2026-10-30T11:00:00Z")
        #expect(await remote.lastSyncDate() != nil)
    }

    @Test func fullSyncDropsCachedItemsTheServerNoLongerHas() async throws {
        let kept = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: kept, storeItemID: "kept")]))
        }
        let (remote, cache) = makeRemote(transport)
        let stale = try decodeItem(itemJSON(storeItemID: "stale", title: "Viejo"))
        try await cache.applyServerChanges(upserts: [stale], deletedIDs: [], replaceAll: false, metadata: [:])
        #expect(try await remote.loadAll().count == 1)
        try await remote.sync()
        #expect(try await remote.loadAll().map(\.id) == [kept])
    }

    @Test func serverIDWinsOverALocalIDForTheSameIdentity() async throws {
        let serverID = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: serverID, storeItemID: "same")]))
        }
        let (remote, cache) = makeRemote(transport)
        let local = try decodeItem(itemJSON(id: UUID(), storeItemID: "same"))
        try await cache.applyServerChanges(upserts: [local], deletedIDs: [], replaceAll: false, metadata: [:])
        try await remote.sync()
        #expect(try await remote.loadAll().map(\.id) == [serverID])
    }

    @Test func syncFailureLeavesTheCacheAndCursorUntouched() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id, title: "Estable")]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()

        transport.respond { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: PriceBucketError.offline) { try await remote.sync() }
        transport.respond { _ in (200, "{ truncated") }
        await #expect(throws: PriceBucketError.invalidResponse) { try await remote.sync() }
        #expect(try await remote.loadAll().map(\.title) == ["Estable"])

        transport.respond { _ in (200, itemsBody(serverTime: "2026-10-30T12:00:00Z", full: false)) }
        try await remote.sync()
        #expect(query(transport.requests.last!)["since"] == "2026-10-30T10:00:00Z")
    }

    @Test func readsWorkOfflineFromTheCache() async throws {
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(title: "Offline")]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        transport.respond { _ in throw URLError(.notConnectedToInternet) }
        let before = transport.requests.count
        #expect(try await remote.loadAll().map(\.title) == ["Offline"])
        #expect(transport.requests.count == before)
    }

    @Test func differentServerURLStartsFromAFullSync() async throws {
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON()]))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PriceTrackerRemoteTests/\(UUID().uuidString)")
        let cache = SQLiteItemStore(databaseURL: directory.appendingPathComponent("c.sqlite"))
        let settings = makeSettings()
        let remote = RemoteItemStore(cache: cache, client: makeClient(transport, settings: settings), settings: settings)
        try await remote.sync()
        try settings.setBaseURL("https://other.example.test")
        try await remote.sync()
        #expect(query(transport.requests[1])["since"] == nil)
    }

    @Test func updateWritesThroughWithPatchThenCaches() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id, target: nil)]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        var edited = try #require(try await remote.loadAll().first)
        edited.targetPriceCents = 4500

        transport.respond { _ in (200, "{\"ok\":true,\"item\":\(itemJSON(id: id, target: 4500))}") }
        let saved = try await remote.upsert(edited)
        #expect(saved.targetPriceCents == 4500)
        #expect(try await remote.loadAll().first?.targetPriceCents == 4500)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "PATCH" && request.url?.path == "/api/v1/items/\(id.uuidString)")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body.keys.sorted() == ["targetPriceCents"])
    }

    @Test func updateWithNothingTheServerStoresMakesNoRequest() async throws {
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON()]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        var item = try #require(try await remote.loadAll().first)
        item.lastAlertedPriceCents = 7
        let count = transport.requests.count
        _ = try await remote.upsert(item)
        #expect(transport.requests.count == count)
    }

    @Test func failedWriteSurfacesTheErrorAndKeepsTheCache() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id, title: "Intacto")]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        var edited = try #require(try await remote.loadAll().first)
        edited.title = "Cambiado"

        transport.respond { _ in throw URLError(.timedOut) }
        await #expect(throws: PriceBucketError.offline) { try await remote.upsert(edited) }
        await #expect(throws: PriceBucketError.offline) { try await remote.delete(id: id) }
        #expect(try await remote.loadAll().map(\.title) == ["Intacto"])
    }

    @Test func deleteCallsTheServerThenRemovesFromCache() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id)]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        transport.respond { _ in (200, "{\"ok\":true,\"left\":0}") }
        try await remote.delete(id: id)
        #expect(try await remote.loadAll().isEmpty)
        #expect(transport.requests.last?.httpMethod == "DELETE")

        // Gone on the server already: converge instead of failing.
        transport.respond { _ in (404, "{}") }
        try await remote.delete(id: id)
    }

    @Test func addPostsTheURLAndCachesAPendingItem() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, "{\"ok\":true,\"item\":\(itemJSON(id: id, store: "amazon", storeItemID: "B000", price: nil, nulls: true))}")
        }
        let (remote, _) = makeRemote(transport)
        let url = URL(string: "https://www.amazon.es/dp/B000")!
        let item = try await remote.add(url: url)
        #expect(item.isPendingFirstCheck)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["url"] as? String == url.absoluteString)
        #expect(try await remote.loadAll().map(\.id) == [id])

        transport.respond { _ in (422, "{\"ok\":false,\"error\":\"Enlace no válido\"}") }
        await #expect(throws: PriceBucketError.validation("Enlace no válido")) { try await remote.add(url: url) }
        #expect(try await remote.loadAll().count == 1)
    }

    @Test func refreshReturnsDeferredAndUpdatesTheCache() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id, price: 999)]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        transport.respond { _ in (200, "{\"ok\":true,\"deferred\":false,\"item\":\(itemJSON(id: id, price: 700))}") }
        let result = try await remote.refresh(id: id)
        #expect(!result.deferred)
        #expect(try await remote.loadAll().first?.priceCurrentCents == 700)

        transport.respond { _ in (200, "{\"ok\":true,\"deferred\":true,\"why\":\"amazon\",\"item\":\(itemJSON(id: id, price: 700))}") }
        #expect(try await remote.refresh(id: id).deferred)
    }

    @Test func historyIsCachedAndReplacedByTheServerList() async throws {
        let id = UUID()
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON(id: id)]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        let item = try #require(try await remote.loadAll().first)

        let itemID = item.id
        let point: @Sendable (UUID, String, Int) -> String = { id, at, cents in
            "{\"id\":\"\(id.uuidString)\",\"itemID\":\"\(itemID.uuidString)\",\"checkedAt\":\"\(at)\",\"priceCents\":\(cents),\"currency\":\"EUR\",\"isOnSale\":false}"
        }
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        transport.respond { _ in
            (200, "{\"observations\":[\(point(p2, "2026-10-30T08:00:00Z", 900)),\(point(p1, "2026-10-25T08:00:00Z", 1200))]}")
        }
        try await remote.refreshHistory(for: item)
        #expect(try await remote.observations(for: item.identityKey).map(\.id) == [p1, p2])

        // Offline: the cached copy is still served.
        transport.respond { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: PriceBucketError.offline) { try await remote.refreshHistory(for: item) }
        #expect(try await remote.observations(for: item.identityKey).count == 2)

        // The server's moving "last check" point replaces the previous one.
        transport.respond { _ in
            (200, "{\"observations\":[\(point(p1, "2026-10-25T08:00:00Z", 1200)),\(point(p3, "2026-10-31T08:00:00Z", 900))]}")
        }
        try await remote.refreshHistory(for: item)
        #expect(try await remote.observations(for: item.identityKey).map(\.id) == [p1, p3])
    }

    @Test func withoutAKeyNothingGoesToTheNetworkAndTheCacheStaysReadable() async throws {
        let transport = FakeTransport()
        let (remote, cache) = makeRemote(transport, key: nil)
        let cached = try decodeItem(itemJSON(title: "Guardado"))
        try await cache.applyServerChanges(upserts: [cached], deletedIDs: [], replaceAll: false, metadata: [:])
        #expect(try await remote.loadAll().map(\.title) == ["Guardado"])
        await #expect(throws: PriceBucketError.notConfigured) { try await remote.sync() }
        await #expect(throws: PriceBucketError.notConfigured) { try await remote.delete(id: cached.id) }
        #expect(transport.requests.isEmpty)
        #expect(!remote.isConfigured)
    }

    @Test func unsupportedLocalOnlyChangesAreRejectedNotSilentlyDropped() async throws {
        let transport = FakeTransport { _ in
            (200, itemsBody(serverTime: "2026-10-30T10:00:00Z", full: true, items: [itemJSON()]))
        }
        let (remote, _) = makeRemote(transport)
        try await remote.sync()
        let current = try #require(try await remote.loadAll().first)
        var changed = current
        changed.priority = .high
        await #expect(throws: PriceBucketError.self) {
            try await remote.commitRefresh(changed, expected: current, observation: nil)
        }
        await #expect(throws: PriceBucketError.self) { try await remote.save([changed]) }
    }
}

// MARK: - Composition

struct RemoteCompositionTests {
    private func temporaryURLs() -> (database: URL, cache: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PriceTrackerEnv/\(UUID().uuidString)")
        return (directory.appendingPathComponent("catalog.sqlite"), directory.appendingPathComponent("remote-cache.sqlite"))
    }

    @Test func demoAndTestModeKeepTheLocalStoreWithoutNetwork() async throws {
        let transport = FakeTransport()
        let urls = temporaryURLs()
        let environment = AppEnvironment(isDemo: true, settings: makeSettings(), transport: transport,
                                         databaseURL: urls.database, remoteCacheURL: urls.cache)
        #expect(environment.remoteStore == nil)
        #expect(!environment.isRemote)
        #expect(environment.itemStore is SQLiteItemStore)
        _ = try await environment.itemStore.loadAll()
        #expect(transport.requests.isEmpty)
        // The test process itself counts as demo (XCTest), so the default composition is local too.
        #expect(AppGroup.isDemo)
        #expect(AppEnvironment.shared.remoteStore == nil)
    }

    @Test func productionUsesTheRemoteStoreBackedByItsOwnCacheFile() async throws {
        let urls = temporaryURLs()
        let environment = AppEnvironment(isDemo: false, settings: makeSettings(key: nil), transport: FakeTransport(),
                                         databaseURL: urls.database, remoteCacheURL: urls.cache)
        #expect(environment.isRemote)
        #expect(environment.itemStore is RemoteItemStore)
        #expect(urls.database != urls.cache)
        #expect(try await environment.itemStore.loadAll().isEmpty)
    }
}
