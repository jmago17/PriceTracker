import Foundation

/// One immutable observation per successful price check, including unchanged
/// prices. The server owns the history; the app caches it in SQLite.
struct PriceObservation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var itemID: UUID
    var checkedAt: Date
    var priceCents: Int
    var currency: String
    var isOnSale: Bool
    var saleEndsAt: Date?
    var availability: String?
}

/// Only connect the latest uninterrupted currency segment. A currency switch
/// cannot be drawn as a price change, even if an earlier segment used this code.
struct PriceHistorySeries {
    let observations: [PriceObservation]

    init(observations: [PriceObservation], currency: String) {
        let ordered = observations.sorted {
            if $0.checkedAt == $1.checkedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.checkedAt < $1.checkedAt
        }
        self.observations = Array(ordered.reversed().prefix {
            $0.currency.caseInsensitiveCompare(currency) == .orderedSame
        }.reversed())
    }

    var hasTimeSpan: Bool {
        guard let first = observations.first, let last = observations.last else { return false }
        return first.checkedAt < last.checkedAt
    }

    var isUnchanged: Bool {
        hasTimeSpan && Set(observations.map(\.priceCents)).count == 1
    }

    var lastPriceChangeAt: Date? {
        Array(zip(observations, observations.dropFirst())).last {
            $0.0.priceCents != $0.1.priceCents
        }?.1.checkedAt
    }
}
