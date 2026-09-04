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
