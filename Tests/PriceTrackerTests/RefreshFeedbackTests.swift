import Foundation
import Testing
@testable import PriceTracker

private actor FeedbackCatalog: PriceHistoryStoring {
    var items: [Item]
    var history: [PriceObservation] = []
    let rejectsWrites: Bool
    init(_ items: [Item], rejectsWrites: Bool = false) { self.items = items; self.rejectsWrites = rejectsWrites }
    func loadAll() -> [Item] { items }
    func save(_ items: [Item]) throws {
        if rejectsWrites { throw ConnectorError.network("disk unavailable") }
        self.items = items
    }
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        let stored = try await upsert(item)
        history.append(observation)
        return stored
    }
    func observations(for identityKey: String) -> [PriceObservation] { history }
}
private actor FeedbackAlerts: AlertStoring {
    var alerts: [PriceAlert] = []
    func loadAll() -> [PriceAlert] { alerts }
    func save(_ alerts: [PriceAlert]) { self.alerts = alerts }
}
private actor FeedbackConnector: StoreConnector {
    nonisolated let store: Store = .appStore
    var calls = 0
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    nonisolated func canResolve(url: URL) -> Bool { false }
    func resolve(url: URL) throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) throws -> FetchResult {
        calls += 1
        if fails { throw ConnectorError.network("HTTP 429") }
        return FetchResult(priceCents: item.priceCurrentCents!, currency: item.currency, isOnSale: false, availability: "available")
    }
}
private actor ReloadLog {
    var dates: [Date?] = []
    func record(_ date: Date?) { dates.append(date) }
}

struct RefreshFeedbackTests {
    private let old = Date(timeIntervalSince1970: 1_700_000_000)
    private let fresh = Date(timeIntervalSince1970: 1_701_209_600)
    private func item(_ store: Store = .appStore) -> Item {
        Item(store: store, storeItemID: UUID().uuidString, canonicalURL: URL(string: "https://example.com/item")!, title: "Artículo", priceCurrentCents: 1000, priceAtAddCents: 1000, priceLowCents: 1000, priceLowAt: old, lastCheckedAt: old, lastSuccessAt: old)
    }

    @Test func unchangedPricePersistsFreshDateBeforeNotifyingReload() async throws {
        let original = item(), now = fresh
        let catalog = FeedbackCatalog([original]), connector = FeedbackConnector(), reload = ReloadLog()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now }, didRefresh: {
            await reload.record(await catalog.loadAll().first?.lastSuccessAt)
        })
        let result = try await coordinator.refreshCatalog()
        let stored = try #require(await catalog.loadAll().first)
        #expect(result.checked == 1 && result.failed == 0 && result.skipped == 0)
        #expect(stored.lastSuccessAt == fresh && stored.lastCheckedAt == fresh)
        #expect(stored.priceLowAt == old && stored.priceCurrentCents == 1000)
        #expect(await catalog.history.map(\.checkedAt) == [fresh])
        #expect(await reload.dates == [fresh])
        #expect(result.completionMessage.contains("Actualizados: 1. Errores: 0."))
    }

    @Test func amazonNowParticipatesInTheCommonRefreshBatch() async throws {
        let original = item(.amazon), now = fresh
        let catalog = FeedbackCatalog([original]), connector = FeedbackConnector()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now })
        let result = try await coordinator.refreshCatalog()
        #expect(result.checked == 1 && result.failed == 0 && result.skipped == 0)
        #expect(result.skippedStores.isEmpty)
        #expect(await connector.calls == 1)
        #expect(await catalog.loadAll().first?.lastSuccessAt == fresh)
        #expect(await catalog.history.count == 1)
        #expect(result.completionMessage.contains("Actualizados: 1."))
    }

    @Test func errorsAndPausedItemsCannotLookLikeAllSuccessful() async throws {
        let apple = item(), amazon = item(.amazon), now = fresh
        var paused = item(); paused.status = .archived
        let catalog = FeedbackCatalog([apple, amazon, paused]), connector = FeedbackConnector(fails: true)
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now })
        let result = try await coordinator.refreshCatalog()
        #expect(result.checked == 2 && result.failed == 2 && result.skipped == 0)
        let stored = try #require(await catalog.loadAll().first { $0.id == apple.id })
        #expect(stored.lastSuccessAt == old && stored.lastCheckedAt == fresh)
        #expect(stored.lastError?.contains("429") == true)
        #expect(result.completionMessage.contains("Actualizados: 0. Errores: 2."))
        #expect(await catalog.loadAll().first { $0.id == paused.id } == paused)
        #expect(await catalog.history.isEmpty)
    }

    @Test func failedPersistenceDoesNotReportSuccessOrNotifyReload() async throws {
        let original = item(), now = fresh
        let catalog = FeedbackCatalog([original], rejectsWrites: true), connector = FeedbackConnector(), reload = ReloadLog()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now }, didRefresh: { await reload.record(now) })
        let result = try await coordinator.refreshCatalog()
        #expect(result.failed == 1)
        #expect(await reload.dates.isEmpty)
        #expect(await catalog.loadAll().first == original)
        #expect(await catalog.history.isEmpty)
    }

    @Test func individualFailureIsReturnedEvenWhenFailureRecordWasPersisted() async {
        let original = item(), now = fresh
        let catalog = FeedbackCatalog([original]), connector = FeedbackConnector(fails: true)
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now })
        let result = await coordinator.refreshResult(id: original.id)
        #expect(result.didPersist && result.error != nil)
        #expect(await catalog.loadAll().first?.lastSuccessAt == old)
    }
    @Test func cancellationIsNotReportedAsCompletedSuccess() async throws {
        let catalog = FeedbackCatalog([item()]), connector = FeedbackConnector()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.refreshCatalog()
        }
        let result = try await task.value
        #expect(result.cancelled && result.checked == 0)
        #expect(result.completionMessage.hasPrefix("Comprobación cancelada."))
        #expect(await connector.calls == 0)
    }

    @Test func categoryRefreshPreservesOtherCategoriesAndPausedItems() async throws {
        var selected = item(); selected.category = "Libros"
        var other = item(); other.category = "Música"
        var paused = item(); paused.category = "Libros"; paused.status = .archived
        let now = fresh
        let catalog = FeedbackCatalog([selected, other, paused]), connector = FeedbackConnector()
        let coordinator = RefreshCoordinator(itemStore: catalog, alertStore: FeedbackAlerts(), connectorToFetch: { _ in connector }, now: { now })
        let result = try await coordinator.refreshCategory("Libros")
        #expect(result.checked == 1)
        let reloaded = await catalog.loadAll()
        #expect(reloaded.first { $0.id == selected.id }?.lastSuccessAt == fresh)
        #expect(reloaded.first { $0.id == other.id } == other)
        #expect(reloaded.first { $0.id == paused.id } == paused)
    }

}
