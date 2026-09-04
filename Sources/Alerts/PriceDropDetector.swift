import Foundation

struct PendingAlertDraft: Equatable, Sendable {
    var kind: AlertKind
    var fromCents: Int?
    var toCents: Int
}

struct PriceEvaluation: Equatable, Sendable {
    var alerts: [PendingAlertDraft]
    var updatedItem: Item
}

/// Pure, side-effect-free price comparison + alert dedup. Deliberately takes no
/// store/clock dependency so it is trivial to unit test (see
/// Tests/PriceTrackerTests/PriceDropDetectorTests.swift).
///
/// Dedup rule from the architecture: an alert fires once per (item, price level);
/// it re-arms only once the price rises back above the level it last fired at.
/// That state lives on `Item.lastAlertedPriceCents`, not in the alert log itself —
/// the log is only a delivery record.
enum PriceDropDetector {
    static func evaluate(item: Item, fetch: FetchResult, now: Date = Date()) -> PriceEvaluation {
        var updated = item
        let newPrice = fetch.priceCents
        let previousPrice = item.priceCurrentCents

        updated.priceCurrentCents = newPrice
        updated.currency = fetch.currency
        updated.onSaleUntil = fetch.saleEndsAt
        if let genre = fetch.storeGenre, updated.category == nil, updated.categorySource != .manual {
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
            if hadPreviousObservation {
                alerts.append(PendingAlertDraft(kind: .lowRecord, fromCents: previousPrice, toCents: newPrice))
            }
        }

        // Re-arm: price rose back above the level we last alerted on.
        if let alertedAt = updated.lastAlertedPriceCents, newPrice > alertedAt {
            updated.lastAlertedPriceCents = nil
        }

        if let target = updated.targetPriceCents, newPrice <= target {
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
