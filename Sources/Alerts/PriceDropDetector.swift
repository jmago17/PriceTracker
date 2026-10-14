import Foundation

struct PendingAlertDraft: Equatable, Sendable {
    var kind: AlertKind
    var fromCents: Int?
    var toCents: Int
    var confirmedSaleEndsAt: Date? = nil
}

struct PriceEvaluation: Equatable, Sendable {
    var alerts: [PendingAlertDraft]
    var updatedItem: Item
}

/// Pure, side-effect-free price comparison + alert dedup. Deliberately takes no
/// store/clock dependency so it is trivial to unit test (see
/// Tests/PriceTrackerTests/PriceDropDetectorTests.swift).
///
/// Drops/targets: an alert fires once per (item, price level);
/// it re-arms only once the price rises back above the level it last fired at.
/// That state lives on `Item.lastAlertedPriceCents`, not in the alert log itself —
/// the log is only a delivery record. Rises instead fire once per initial-price
/// generation, persisted and synced in Item metadata; only an explicit reset or
/// currency baseline change creates a new generation.
enum PriceDropDetector {
    static func evaluate(item: Item, fetch: FetchResult, now: Date = Date()) -> PriceEvaluation {
        var updated = item
        guard fetch.priceCents >= 0 else { return PriceEvaluation(alerts: [], updatedItem: item) }
        let newPrice = fetch.priceCents
        let newCurrency = fetch.currency.uppercased()
        let currencyChanged = item.currency.caseInsensitiveCompare(newCurrency) != .orderedSame

        // Amounts in different currencies are not comparable. A storefront
        // switch (for example EUR -> USD) establishes a fresh baseline and
        // must never be reported as a discount or target hit.
        if currencyChanged {
            updated.priceCurrentCents = newPrice
            updated.priceAtAddCents = newPrice
            updated.renewInitialPriceGeneration()
            updated.priceReferenceCents = nil
            updated.priceLowCents = newPrice
            updated.priceLowAt = now
            updated.targetPriceCents = nil
            updated.lastAlertedPriceCents = nil
            updated.currency = newCurrency
            updated.onSaleUntil = fetch.saleEndsAt
            if let genre = CategoryLabel.suggestion(fetch.storeGenre), updated.category == nil, updated.categorySource != .manual {
                updated.category = genre
                updated.categorySource = .mapped
            }
            if let title = fetch.title, !title.isEmpty { updated.title = title }
            if let imageURL = fetch.imageURL { updated.imageURL = imageURL }
            updated.lastCheckedAt = now
            updated.lastSuccessAt = now
            updated.consecutiveFailures = 0
            updated.lastError = nil
            if updated.status == .unavailable || updated.status == .stale { updated.status = .active }
            updated.updatedAt = now
            return PriceEvaluation(alerts: [], updatedItem: updated)
        }

        let previousPrice = item.priceCurrentCents

        updated.priceCurrentCents = newPrice
        updated.currency = newCurrency
        updated.onSaleUntil = fetch.saleEndsAt
        if let genre = CategoryLabel.suggestion(fetch.storeGenre), updated.category == nil, updated.categorySource != .manual {
            updated.category = genre
            updated.categorySource = .mapped
        }
        if let title = fetch.title, !title.isEmpty { updated.title = title }
        if let imageURL = fetch.imageURL { updated.imageURL = imageURL }
        updated.lastCheckedAt = now
        updated.lastSuccessAt = now
        updated.consecutiveFailures = 0
        updated.lastError = nil
        if updated.status == .unavailable || updated.status == .stale { updated.status = .active }
        updated.updatedAt = now

        var alerts: [PendingAlertDraft] = []

        // Low record — never fires on the very first observed price.
        let hadPreviousObservation = previousPrice != nil
        if updated.priceLowCents == nil || newPrice < updated.priceLowCents! {
            updated.priceLowCents = newPrice
            updated.priceLowAt = now
            if hadPreviousObservation && previousPrice != newPrice {
                alerts.append(PendingAlertDraft(kind: .lowRecord, fromCents: previousPrice, toCents: newPrice))
            }
        }

        // Re-arm: price rose back above the level we last alerted on.
        if let alertedAt = updated.lastAlertedPriceCents, newPrice > alertedAt {
            updated.lastAlertedPriceCents = nil
        }

        if previousPrice != nil, previousPrice != newPrice, let target = updated.targetPriceCents, newPrice <= target {
            if updated.lastAlertedPriceCents == nil || newPrice < updated.lastAlertedPriceCents! {
                alerts.append(PendingAlertDraft(kind: .targetHit, fromCents: previousPrice, toCents: newPrice))
                updated.lastAlertedPriceCents = newPrice
            }
        } else if let previous = previousPrice, newPrice < previous {
            if updated.lastAlertedPriceCents == nil || newPrice < updated.lastAlertedPriceCents! {
                alerts.append(PendingAlertDraft(kind: .drop, fromCents: previous, toCents: newPrice))
                updated.lastAlertedPriceCents = newPrice
            }
        }

        if let initial = item.priceAtAddCents, initial >= 0,
           newPrice > initial, !item.hasAlertedInitialPriceRise {
            alerts.append(PendingAlertDraft(kind: .priceChange, fromCents: initial, toCents: newPrice))
            updated.markInitialPriceRiseAlerted()
        }
        // A historical reduction alone is not proof of a time-limited offer.
        if fetch.isOnSale, let end = fetch.saleEndsAt, end > now,
           let previousPrice, newPrice < previousPrice, item.priority == .high {
            let offerKey = "PriceTracker.urgentOffer.\(newCurrency)|\(Int64(end.timeIntervalSince1970.rounded()))"
            if updated.externalIDs[offerKey] != "true", !alerts.isEmpty {
                for index in alerts.indices where alerts[index].kind != .priceChange {
                    alerts[index].confirmedSaleEndsAt = end
                }
                if alerts.contains(where: { $0.confirmedSaleEndsAt != nil }) {
                    updated.externalIDs[offerKey] = "true"
                }
            }
        }
        return PriceEvaluation(alerts: alerts, updatedItem: updated)
    }

    /// Applied when a connector's `fetch` throws. Marks the item `.stale` after
    /// 3 consecutive failures — see architecture §d "Salud del pipeline".
    static func applyFailure(to item: Item, error: Error, now: Date = Date()) -> Item {
        var updated = item
        updated.consecutiveFailures += 1
        updated.lastCheckedAt = now
        updated.lastError = error.localizedDescription
        updated.updatedAt = now
        if updated.consecutiveFailures >= 3 {
            updated.status = .stale
        }
        return updated
    }
}
