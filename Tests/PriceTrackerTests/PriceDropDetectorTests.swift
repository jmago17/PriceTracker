import Foundation
import Testing
@testable import PriceTracker

private func makeItem(priceCurrentCents: Int?, targetPriceCents: Int? = nil, priceLowCents: Int? = nil, lastAlertedPriceCents: Int? = nil) -> Item {
    Item(
        store: .appStore,
        storeItemID: "111",
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id111")!,
        title: "Hades II",
        priceCurrentCents: priceCurrentCents,
        priceLowCents: priceLowCents,
        targetPriceCents: targetPriceCents,
        lastAlertedPriceCents: lastAlertedPriceCents
    )
}

private func fetch(_ cents: Int) -> FetchResult {
    FetchResult(priceCents: cents, currency: "EUR", isOnSale: cents > 0, saleEndsAt: nil, availability: "available")
}

struct PriceDropDetectorTests {
    @Test func firstObservationSetsBaselineWithoutAlerting() {
        let item = makeItem(priceCurrentCents: nil)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(2999))
        #expect(evaluation.alerts.isEmpty, "the very first price should never look like a 'record' or a 'drop'")
        #expect(evaluation.updatedItem.priceCurrentCents == 2999)
        #expect(evaluation.updatedItem.priceLowCents == 2999)
    }

    @Test func priceDropFiresOnceAndSetsLastAlertedPrice() {
        let item = makeItem(priceCurrentCents: 2999, priceLowCents: 2999)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(1999))

        #expect(evaluation.alerts.contains(PendingAlertDraft(kind: .drop, fromCents: 2999, toCents: 1999)))
        #expect(evaluation.alerts.contains(PendingAlertDraft(kind: .lowRecord, fromCents: 2999, toCents: 1999)))
        #expect(evaluation.updatedItem.lastAlertedPriceCents == 1999)
    }

    @Test func sameDroppedPriceDoesNotAlertTwice() {
        // The dedup rule: an alert fires once per (item, price level).
        let item = makeItem(priceCurrentCents: 1999, priceLowCents: 1999, lastAlertedPriceCents: 1999)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(1999))
        #expect(evaluation.alerts.isEmpty)
    }

    @Test func priceRisingBackAboveAlertedLevelRearms() {
        let item = makeItem(priceCurrentCents: 1999, priceLowCents: 1999, lastAlertedPriceCents: 1999)
        let risen = PriceDropDetector.evaluate(item: item, fetch: fetch(2499))
        #expect(risen.updatedItem.lastAlertedPriceCents == nil, "rising back above the alerted level should re-arm")

        // Dropping to that same level again should now alert again.
        let droppedAgain = PriceDropDetector.evaluate(item: risen.updatedItem, fetch: fetch(1999))
        #expect(droppedAgain.alerts.contains(PendingAlertDraft(kind: .drop, fromCents: 2499, toCents: 1999)))
    }

    @Test func targetHitTakesPriorityOverPlainDrop() {
        let item = makeItem(priceCurrentCents: 2999, targetPriceCents: 2000, priceLowCents: 2999)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(1500))

        #expect(evaluation.alerts.contains(PendingAlertDraft(kind: .targetHit, fromCents: 2999, toCents: 1500)))
        #expect(!evaluation.alerts.contains(where: { $0.kind == .drop }), "targetHit and drop are mutually exclusive for the same price move")
    }

    @Test func newLowRecordIsTrackedAcrossChecks() {
        let item = makeItem(priceCurrentCents: 1999, priceLowCents: 1999)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(999))
        #expect(evaluation.updatedItem.priceLowCents == 999)
        #expect(evaluation.updatedItem.priceLowAt != nil)
    }

    @Test func failureIncrementsCounterAndMarksStaleAtThreshold() {
        var item = makeItem(priceCurrentCents: 999)
        let error = ConnectorError.network("timeout")

        item = PriceDropDetector.applyFailure(to: item, error: error)
        #expect(item.consecutiveFailures == 1)
        #expect(item.status != .stale)

        item = PriceDropDetector.applyFailure(to: item, error: error)
        item = PriceDropDetector.applyFailure(to: item, error: error)
        #expect(item.consecutiveFailures == 3)
        #expect(item.status == .stale)
    }

    @Test func successfulRefreshClearsFailureState() {
        var item = makeItem(priceCurrentCents: 999)
        item = PriceDropDetector.applyFailure(to: item, error: ConnectorError.network("x"))
        #expect(item.consecutiveFailures == 1)

        let evaluation = PriceDropDetector.evaluate(item: item, fetch: fetch(999))
        #expect(evaluation.updatedItem.consecutiveFailures == 0)
        #expect(evaluation.updatedItem.lastError == nil)
    }
}


extension PriceDropDetectorTests {
    @Test func currencyChangeCreatesFreshBaselineWithoutFalseDrop() {
        var item = makeItem(priceCurrentCents: 1499, targetPriceCents: 1200, priceLowCents: 1499, lastAlertedPriceCents: 1499)
        item.currency = "EUR"
        item.priceAtAddCents = 1499

        let usd = FetchResult(priceCents: 1299, currency: "USD", isOnSale: false, saleEndsAt: nil, availability: "available")
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: usd)

        #expect(evaluation.alerts.isEmpty)
        #expect(evaluation.updatedItem.currency == "USD")
        #expect(evaluation.updatedItem.priceCurrentCents == 1299)
        #expect(evaluation.updatedItem.priceAtAddCents == 1299)
        #expect(evaluation.updatedItem.priceLowCents == 1299)
        #expect(evaluation.updatedItem.targetPriceCents == nil)
        #expect(evaluation.updatedItem.lastAlertedPriceCents == nil)
    }
}

private struct HistoryTestConnector: StoreConnector {
    let store: Store = .appStore
    let result: Result<FetchResult, ConnectorError>
    func canResolve(url: URL) -> Bool { true }
    func resolve(url: URL) async throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) async throws -> FetchResult { try result.get() }
}

private actor HistoryTestAlerts: AlertStoring {
    var alerts: [PriceAlert] = []
    func loadAll() -> [PriceAlert] { alerts }
    func save(_ alerts: [PriceAlert]) { self.alerts = alerts }
}

struct PriceHistoryRefreshTests {
    @Test func equalChangedAndFailedChecksPersistOnlyRealSuccesses() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.sqlite")
        let store = SQLiteItemStore(databaseURL: databaseURL)
        let alerts = HistoryTestAlerts()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let item = Item(store: .appStore, storeItemID: "1", canonicalURL: URL(string: "https://apps.apple.com/us/app/id1")!, title: "Test",
            priceCurrentCents: 1499, priceAtAddCents: 1499, priceReferenceCents: 1999, priceLowCents: 1499,
            lastCheckedAt: old, lastSuccessAt: old)
        try await store.upsert(item)
        #expect(try await store.observations(for: item.identityKey).isEmpty) // No backfill.
        for (index, cents) in [1499, 1499, 999].enumerated() {
            let date = old.addingTimeInterval(Double(index + 1) * 3600)
            let fetch = FetchResult(priceCents: cents, currency: "EUR", isOnSale: false, availability: "available")
            let connector = HistoryTestConnector(result: .success(fetch))
            let coordinator = RefreshCoordinator(itemStore: store, alertStore: alerts,
                connectorToFetch: { _ in connector }, now: { date })
            #expect(try await coordinator.refreshItem(id: item.id))
            let loaded = try #require(try await store.item(id: item.id))
            #expect(loaded.lastSuccessAt == date)
            #expect(loaded.lastCheckedAt == date)
            #expect(loaded.priceReferenceCents == 1999)
            #expect(loaded.priceAtAddCents == 1499)
            #expect(loaded.onSaleUntil == nil)
            let history = try await store.observations(for: item.identityKey)
            #expect(history.count == index + 1)
            #expect(history.last?.checkedAt == date)
            #expect(history.last?.priceCents == cents)
            if index < 2 { #expect(await alerts.loadAll().isEmpty) }
            if index == 0 { #expect(!PriceHistorySeries(observations: history, currency: "EUR").hasTimeSpan) }
            if index == 1 { #expect(PriceHistorySeries(observations: history, currency: "EUR").isUnchanged) }
        }
        let failureDate = old.addingTimeInterval(14400)
        let failing = HistoryTestConnector(result: .failure(.network("offline")))
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: alerts,
            connectorToFetch: { _ in failing }, now: { failureDate })
        #expect(try await !coordinator.refreshItem(id: item.id))
        let failed = try #require(try await store.item(id: item.id))
        #expect(failed.lastCheckedAt == failureDate)
        #expect(failed.lastSuccessAt == old.addingTimeInterval(10800))
        #expect(failed.priceCurrentCents == 999)
        #expect(failed.lastError != nil)
        let reopened = SQLiteItemStore(databaseURL: databaseURL)
        let history = try await reopened.observations(for: item.identityKey)
        #expect(history.map(\.priceCents) == [1499, 1499, 999])
        #expect(PriceHistorySeries(observations: history, currency: "EUR").lastPriceChangeAt == old.addingTimeInterval(10800))
    }

    @Test func historySeparatesCurrencySegmentsAndHonorsSinglePoint() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let values: [(String, Int)] = [("USD", 100), ("EUR", 200), ("USD", 100), ("USD", 100)]
        let observations = values.enumerated().map { index, value in
            PriceObservation(itemID: id, checkedAt: base.addingTimeInterval(Double(index)), priceCents: value.1, currency: value.0, isOnSale: false)
        }
        let series = PriceHistorySeries(observations: observations, currency: "USD")
        #expect(series.observations.count == 2)
        #expect(series.isUnchanged)
        #expect(series.lastPriceChangeAt == nil)
        #expect(PriceHistorySeries(observations: Array(observations.prefix(3)), currency: "USD").observations.count == 1)
        #expect(PriceHistorySeries(observations: observations, currency: "EUR").observations.isEmpty)
        #expect(!PriceHistorySeries(observations: [observations[0]], currency: "USD").hasTimeSpan)
        #expect(base.relativeSpanish(to: base.addingTimeInterval(10)) == "ahora")
        #expect(base.relativeSpanish(to: base.addingTimeInterval(4 * 86400)) != "ahora")
    }
}

extension PriceHistoryRefreshTests {
    @Test func catalogRefreshRecordsEqualPriceAndSkipsUnrefreshableLinks() async throws {
        let store = SQLiteItemStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.sqlite"))
        let app = Item(store: .appStore, storeItemID: "catalog-app", canonicalURL: URL(string: "https://apps.apple.com/us/app/id1")!, title: "App", priceCurrentCents: 100)
        let link = Item(store: .generic, storeItemID: "link", canonicalURL: URL(string: "https://example.com")!, title: "Link", priceCurrentCents: 100)
        try await store.save([app, link])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let connector = HistoryTestConnector(result: .success(FetchResult(priceCents: 100, currency: "EUR", isOnSale: false, availability: "available")))
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: HistoryTestAlerts(), connectorToFetch: { _ in connector }, now: { date })
        let summary = try await coordinator.refreshCatalog()
        #expect(summary.checked == 1)
        #expect(summary.failed == 0)
        #expect(summary.skipped == 1)
        #expect(try await store.item(id: app.id)?.lastSuccessAt == date)
        #expect(try await store.observations(for: app.identityKey).count == 1)
        #expect(try await store.observations(for: link.identityKey).isEmpty)
        #expect(try await store.item(id: link.id)?.lastSuccessAt == nil)
    }
}
