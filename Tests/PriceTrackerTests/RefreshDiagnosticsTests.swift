import Foundation
import Testing
@testable import PriceTracker

private actor DiagnosticCatalog: PriceHistoryStoring {
    var items: [Item]
    var history: [PriceObservation] = []
    let rejectsWrites: Bool
    init(_ item: Item, rejectsWrites: Bool = false) { items = [item]; self.rejectsWrites = rejectsWrites }
    func loadAll() -> [Item] { items }
    func save(_ values: [Item]) throws {
        if rejectsWrites { throw ConnectorError.network("secret-disk-path") }
        items = values
    }
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        let stored = try await upsert(item); history.append(observation); return stored
    }
    func observations(for identityKey: String) -> [PriceObservation] { history }
}
private actor DiagnosticAlerts: AlertStoring {
    var values: [PriceAlert] = []
    let rejectsWrites: Bool
    init(rejectsWrites: Bool = false) { self.rejectsWrites = rejectsWrites }
    func loadAll() -> [PriceAlert] { values }
    func save(_ values: [PriceAlert]) throws {
        if rejectsWrites { throw ConnectorError.network("private-account-token") }
        self.values = values
    }
}
private actor DiagnosticConnector: StoreConnector {
    nonisolated let store: Store = .amazon
    let failure: WebPriceError?
    var calls = 0
    init(_ failure: WebPriceError? = nil) { self.failure = failure }
    nonisolated func canResolve(url: URL) -> Bool { false }
    func resolve(url: URL) throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) throws -> FetchResult {
        calls += 1
        if let failure { throw failure }
        return FetchResult(priceCents: 900, currency: "EUR", isOnSale: false, availability: "available")
    }
}

struct RefreshDiagnosticsTests {
    private let old = Date(timeIntervalSince1970: 1_700_000_000)
    private func item() -> Item {
        Item(store: .amazon, storeItemID: "private-product-id", canonicalURL: URL(string: "https://user:password@example.com/private-path?token=secret#account")!, title: "private-title", priceCurrentCents: 1000, priceAtAddCents: 1100, priceLowCents: 950, lastCheckedAt: old, lastSuccessAt: old)
    }
    private func attempt(itemID: UUID, at: Date = Date(), id: UUID = UUID()) -> RefreshDiagnosticAttempt {
        RefreshDiagnosticAttempt(id: id, itemID: itemID, store: .amazon, startedAt: at, duration: 0.2,
            lastSuccessAt: old, failure: RefreshDiagnosticFailure(code: .identity, phase: .validation), alertFailure: nil)
    }

    @Test(arguments: [WebPriceError.response(403), .response(429), .response(503), .blocked, .identity, .variant, .currency, .conflict, .conditions, .missing])
    func failuresKeepPricesHistoryAndSuccess(failure: WebPriceError) async throws {
        let original = item(), catalog = DiagnosticCatalog(item()), log = RefreshDiagnostics()
        // Use the same identity/UUID in the store and in the request.
        try await catalog.save([original])
        let connector = DiagnosticConnector(failure), date = old.addingTimeInterval(300)
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: DiagnosticAlerts(), connectorToFetch: { _ in connector }, now: { date }, diagnostics: log)
        let result = await coordinator.refreshResult(id: original.id)
        let stored = try #require(await catalog.loadAll().first)
        #expect(result.didPersist && result.error != nil)
        var expected = original
        expected.lastCheckedAt = date; expected.updatedAt = date; expected.consecutiveFailures += 1
        expected.lastError = RefreshDiagnosticFailure.classify(failure, phase: .download).errorDescription
        #expect(stored == expected)
        #expect(await catalog.history.isEmpty)
        let entry = try #require(await log.snapshot(itemID: original.id).first)
        #expect(entry.failure?.code == RefreshDiagnosticFailure.classify(failure, phase: .download).code)
        #expect(entry.lastSuccessAt == old && entry.duration >= 0)
        let report = RefreshDiagnostics.report([entry])
        for secret in ["private-title", "private-product-id", "user", "password", "example.com", "private-path", "token=", "#account", original.id.uuidString] {
            #expect(!report.contains(secret))
        }
        #expect(report.contains(entry.id.uuidString))
    }

    @Test func arbitraryErrorsCannotEscapeTheClosedVocabulary() {
        let secret = "https://user:password@host/path?token=secret#private Cookie: account <html>secret</html>"
        let errors: [any Error] = [ConnectorError.network(secret), ConnectorError.decoding(secret), ConnectorError.notSupported(secret), NSError(domain: secret, code: 999, userInfo: [NSLocalizedDescriptionKey: secret]), URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: secret])]
        for error in errors {
            let safe = RefreshDiagnosticFailure.classify(error, phase: .download)
            #expect(!(safe.errorDescription ?? "").contains("secret"))
            #expect(!(safe.errorDescription ?? "").contains("https"))
        }
    }

    @Test func phasePreventsStorageAndDeliveryBeingMislabelledAsFetch() {
        let typed = RefreshDiagnosticFailure(code: .network, phase: .download)
        #expect(RefreshDiagnosticFailure.classify(typed, phase: .persistence).code == .persistence)
        #expect(RefreshDiagnosticFailure.classify(WebPriceError.response(403), phase: .alerts).code == .alerts)
        #expect(RefreshDiagnosticFailure.classify(RefreshError.itemNotFound, phase: .persistence).code == .missingItem)
    }

    @Test func limitsTTLDeduplicationAndConcurrentCallbacks() async {
        let now = Date(), a = UUID(), b = UUID(), log = RefreshDiagnostics(capacity: 3, perItemLimit: 2, ttl: 60)
        let one = attempt(itemID: a, at: now)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { await log.record(one, now: now) } }
        }
        #expect(await log.snapshot(itemID: a, now: now).count == 1)
        await log.record(attempt(itemID: a, at: now), now: now)
        await log.record(attempt(itemID: a, at: now), now: now)
        #expect(await log.snapshot(itemID: a, now: now).count == 2)
        await log.record(attempt(itemID: b, at: now), now: now)
        await log.record(attempt(itemID: b, at: now), now: now)
        #expect(await log.snapshot(itemID: a, now: now).count == 1)
        #expect(await log.snapshot(itemID: b, now: now).count == 2)
        #expect(await log.snapshot(itemID: a, now: now.addingTimeInterval(61)).isEmpty)
        #expect(await log.snapshot(itemID: b, now: now.addingTimeInterval(61)).isEmpty)
    }

    @Test(arguments: [false, true])
    func persistenceFailureDoesNotMutateItemOrMasqueradeAsNetwork(failsFetch: Bool) async throws {
        let original = item(), log = RefreshDiagnostics()
        let store = DiagnosticCatalog(original, rejectsWrites: true)
        let connector = DiagnosticConnector(failsFetch ? .identity : nil)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: DiagnosticAlerts(), connectorToFetch: { _ in connector }, diagnostics: log)
        let result = await coordinator.refreshResult(id: original.id)
        #expect(!result.didPersist && result.error != nil)
        #expect(await store.loadAll().first == original)
        #expect(await store.history.isEmpty)
        let entry = try #require(await log.snapshot(itemID: original.id).first)
        #expect(entry.failure?.code == .persistence && entry.failure?.phase == .persistence)
        #expect(entry.precedingFailure?.code == (failsFetch ? .identity : nil))
        #expect(!RefreshDiagnostics.report([entry]).contains("secret-disk-path"))
    }

    @Test func alertFailureRemainsIndependentOfSuccessfulPrice() async throws {
        let original = item(), catalog = DiagnosticCatalog(item()), log = RefreshDiagnostics()
        try await catalog.save([original])
        let connector = DiagnosticConnector()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: DiagnosticAlerts(rejectsWrites: true), connectorToFetch: { _ in connector }, diagnostics: log)
        let result = await coordinator.refreshResult(id: original.id)
        #expect(result.didPersist && result.error == nil && result.notificationError != nil)
        #expect(await catalog.loadAll().first?.priceCurrentCents == 900)
        #expect(await catalog.history.count == 1)
        let entry = try #require(await log.snapshot(itemID: original.id).first)
        #expect(entry.failure == nil && entry.alertFailure?.code == .alerts)
        #expect(!RefreshDiagnostics.report([entry]).contains("private-account-token"))
    }

    @Test func cancellationDoesNotChangeCatalogOrFreshness() async throws {
        let original = item(), log = RefreshDiagnostics(), connector = DiagnosticConnector()
        let catalog = DiagnosticCatalog(original)
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: DiagnosticAlerts(), connectorToFetch: { _ in connector }, diagnostics: log)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.refreshResult(id: original.id)
        }
        let result = await task.value
        #expect(!result.didPersist && result.error != nil)
        #expect(await catalog.loadAll().first == original)
        #expect(await connector.calls == 0)
        #expect(await catalog.history.isEmpty)
        let entry = try #require(await log.snapshot(itemID: original.id).first)
        #expect(entry.failure?.code == .cancelled)
        #expect(entry.lastSuccessAt == nil) // cancelled before reading the item
    }

    @Test func concurrentRequestsProduceOneDistinctRecordPerActualFetch() async {
        let original = item(), catalog = DiagnosticCatalog(item()), log = RefreshDiagnostics(), connector = DiagnosticConnector(.identity)
        try? await catalog.save([original])
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: DiagnosticAlerts(), connectorToFetch: { _ in connector }, diagnostics: log)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await coordinator.refreshResult(id: original.id) } }
        }
        let attempts = await log.snapshot(itemID: original.id)
        #expect(await connector.calls == 10)
        #expect(attempts.count == 10 && Set(attempts.map(\.id)).count == 10)
        #expect(await catalog.loadAll().first?.consecutiveFailures == 10)
        #expect(await catalog.history.isEmpty)
        await log.clear(itemID: original.id)
        #expect(await log.snapshot(itemID: original.id).isEmpty)
    }
}
