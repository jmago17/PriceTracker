import Foundation
import Testing
import UserNotifications
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
    @Test func catalogRefreshRecordsEqualPriceForAppsAndSupportedWebLinks() async throws {
        let store = SQLiteItemStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("catalog.sqlite"))
        let app = Item(store: .appStore, storeItemID: "catalog-app", canonicalURL: URL(string: "https://apps.apple.com/us/app/id1")!, title: "App", priceCurrentCents: 100)
        let link = Item(store: .generic, storeItemID: "link", canonicalURL: URL(string: "https://example.com")!, title: "Link", priceCurrentCents: 100)
        try await store.save([app, link])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let connector = HistoryTestConnector(result: .success(FetchResult(priceCents: 100, currency: "EUR", isOnSale: false, availability: "available")))
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: HistoryTestAlerts(), connectorToFetch: { _ in connector }, now: { date })
        let summary = try await coordinator.refreshCatalog()
        #expect(summary.checked == 2)
        #expect(summary.failed == 0)
        #expect(summary.skipped == 0)
        #expect(try await store.item(id: app.id)?.lastSuccessAt == date)
        #expect(try await store.observations(for: app.identityKey).count == 1)
        #expect(try await store.observations(for: link.identityKey).count == 1)
        #expect(try await store.item(id: link.id)?.lastSuccessAt == date)
    }
}

extension PriceDropDetectorTests {
    @Test func riseIsOncePerInitialPriceAcrossReloadsAndFluctuations() throws {
        var item = makeItem(priceCurrentCents: 1000, priceLowCents: 1000)
        item.priceAtAddCents = 1000
        let first = PriceDropDetector.evaluate(item: item, fetch: fetch(1200))
        #expect(first.alerts.filter { $0.kind == .priceChange }.count == 1)
        #expect(first.alerts.first?.fromCents == 1000)
        item = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(first.updatedItem))
        for price in [1200, 1400, 900, 1600] {
            let result = PriceDropDetector.evaluate(item: item, fetch: fetch(price))
            #expect(!result.alerts.contains { $0.kind == .priceChange })
            item = result.updatedItem
        }
    }

    @Test func recoveryBelowInitialDoesNotCountAsRise() {
        var item = makeItem(priceCurrentCents: 500, priceLowCents: 500)
        item.priceAtAddCents = 1000
        #expect(PriceDropDetector.evaluate(item: item, fetch: fetch(800)).alerts.isEmpty)
        #expect(PriceDropDetector.evaluate(item: item, fetch: fetch(1000)).alerts.isEmpty)
    }

    @Test func resetRearmsOnlyFutureRiseAndPreservesRealHistoryFields() {
        var item = makeItem(priceCurrentCents: 1000, targetPriceCents: 500, priceLowCents: 700, lastAlertedPriceCents: 800)
        item.priceAtAddCents = 1000
        item.priceReferenceCents = 2000
        item = PriceDropDetector.evaluate(item: item, fetch: fetch(1200)).updatedItem
        let lowDate = item.priceLowAt, created = item.createdAt
        let didReset1 = item.useCurrentPriceAsInitial()
        #expect(didReset1)
        #expect(item.priceAtAddCents == 1200)
        #expect(item.priceReferenceCents == 2000 && item.priceLowCents == 700)
        #expect(item.priceLowAt == lowDate && item.createdAt == created && item.targetPriceCents == 500)
        #expect(PriceDropDetector.evaluate(item: item, fetch: fetch(1200)).alerts.isEmpty)
        #expect(PriceDropDetector.evaluate(item: item, fetch: fetch(1300)).alerts.contains { $0.kind == .priceChange })
        let key = item.initialPriceAlertKey
        let didReset2 = item.useCurrentPriceAsInitial()
        #expect(didReset2)
        #expect(item.initialPriceAlertKey != key)
    }

    @Test func failureInvalidPriceAndCurrencyDoNotTriggerRise() {
        var item = makeItem(priceCurrentCents: 1000)
        item.priceAtAddCents = 1000
        let failed = PriceDropDetector.applyFailure(to: item, error: ConnectorError.network("offline"))
        #expect(!failed.hasAlertedInitialPriceRise && !failed.canUseCurrentPriceAsInitial)
        #expect(PriceDropDetector.evaluate(item: item, fetch: fetch(-1)).alerts.isEmpty)
        let changed = PriceDropDetector.evaluate(item: item, fetch: FetchResult(priceCents: 2000, currency: "USD", isOnSale: false, availability: "available"))
        #expect(changed.alerts.isEmpty && changed.updatedItem.priceAtAddCents == 2000)
        #expect(!changed.updatedItem.hasAlertedInitialPriceRise)
    }

    @Test func prioritiesDefaultRoundTripAndUnknownValue() throws {
        var item = makeItem(priceCurrentCents: 1000)
        #expect(item.priority == .normal)
        item.priority = .high
        let reloaded = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(item))
        #expect(reloaded.priority == .high)
        item.externalIDs["PriceTracker.priority"] = "future"
        #expect(item.priority == .normal)
        item.priority = .low
        #expect(item.priority == .low)
    }

    @Test func timeSensitiveRequiresOptInPriorityAndConfirmedUnexpiredDiscount() {
        let now = Date(), end = Date().addingTimeInterval(300)
        var item = makeItem(priceCurrentCents: 1000, priceLowCents: 1000)
        item.priority = .high
        let result = PriceDropDetector.evaluate(item: item, fetch: FetchResult(priceCents: 800, currency: "EUR", isOnSale: true, saleEndsAt: end, availability: "available"), now: now)
        let draft = result.alerts.first!
        var alert = PriceAlert(itemID: item.id, kind: draft.kind, priceFromCents: draft.fromCents, priceToCents: draft.toCents, confirmedSaleEndsAt: draft.confirmedSaleEndsAt)
        item = result.updatedItem
        #expect(AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: true, now: now))
        #expect(!AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: false, now: now))
        #expect(!AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: true, now: end))
        item.priority = .normal
        #expect(!AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: true, now: now))
        item.priority = .high
        alert.kind = .priceChange
        #expect(!AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: true, now: now))
        alert.kind = .drop; alert.confirmedSaleEndsAt = nil
        #expect(!AlertNotifier.qualifiesForTimeSensitive(alert, item: item, optedIn: true, now: now))
        let repeatCheck = PriceDropDetector.evaluate(item: item, fetch: FetchResult(priceCents: 800, currency: "EUR", isOnSale: true, saleEndsAt: end, availability: "available"))
        #expect(repeatCheck.alerts.isEmpty)
    }
}


extension PriceDropDetectorTests {
    @Test func sameOfferDoesNotBecomeTimeSensitiveAgainAfterRebound() {
        let end = Date().addingTimeInterval(600)
        var item = makeItem(priceCurrentCents: 1000, priceLowCents: 1000)
        item.priority = .high
        let offer = FetchResult(priceCents: 800, currency: "EUR", isOnSale: true, saleEndsAt: end, availability: "available")
        let first = PriceDropDetector.evaluate(item: item, fetch: offer)
        #expect(first.alerts.contains { $0.confirmedSaleEndsAt == end })
        item = PriceDropDetector.evaluate(item: first.updatedItem, fetch: fetch(1000)).updatedItem
        let repeated = PriceDropDetector.evaluate(item: item, fetch: offer)
        #expect(!repeated.alerts.isEmpty) // Existing normal drop policy remains.
        #expect(repeated.alerts.allSatisfy { $0.confirmedSaleEndsAt == nil })
        #expect(AlertNotifier.interruptionLevel(timeSensitive: true, allowed: true) == .timeSensitive)
        #expect(AlertNotifier.interruptionLevel(timeSensitive: true, allowed: false) == .active)
        #expect(AlertNotifier.interruptionLevel(timeSensitive: false, allowed: true) == .active)
    }
}


extension PriceDropDetectorTests {
    @Test func savedInitialPriceIsEnoughEvenIfImportedCurrentPriceIsMissing() {
        var item = makeItem(priceCurrentCents: nil)
        item.priceAtAddCents = 1000
        let result = PriceDropDetector.evaluate(item: item, fetch: fetch(1200))
        #expect(result.alerts.filter { $0.kind == .priceChange }.count == 1)
        #expect(result.updatedItem.hasAlertedInitialPriceRise)
    }
}

extension PriceDropDetectorTests {
    @Test func disconfirmedOfferInvalidatesPendingUrgencyAcrossReload() throws {
        let now = Date(), end = now.addingTimeInterval(3600)
        var item = makeItem(priceCurrentCents: 2000, priceLowCents: 2000)
        item.priority = .high
        let offer = FetchResult(priceCents: 1500, currency: "EUR", isOnSale: true, saleEndsAt: end, availability: "available")
        let first = PriceDropDetector.evaluate(item: item, fetch: offer, now: now)
        let draft = try #require(first.alerts.last)
        let pending = PriceAlert(itemID: item.id, kind: draft.kind, priceFromCents: draft.fromCents,
                                 priceToCents: draft.toCents, confirmedSaleEndsAt: draft.confirmedSaleEndsAt)
        #expect(AlertNotifier.qualifiesForTimeSensitive(pending, item: first.updatedItem, optedIn: true, now: now))
        var disconfirmed = offer
        disconfirmed.isOnSale = false
        let next = PriceDropDetector.evaluate(item: first.updatedItem, fetch: disconfirmed, now: now)
        let reloaded = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(next.updatedItem))
        #expect(reloaded.onSaleUntil == nil)
        #expect(next.alerts.isEmpty)
        #expect(!AlertNotifier.qualifiesForTimeSensitive(pending, item: reloaded, optedIn: true, now: now))
        // Currency changes must also discard an unconfirmed expiry.
        disconfirmed.currency = "USD"
        let changed = PriceDropDetector.evaluate(item: first.updatedItem, fetch: disconfirmed, now: now)
        #expect(changed.updatedItem.onSaleUntil == nil && changed.alerts.isEmpty)
    }
}
