import Foundation

/// One row per price *change*, not per check — see architecture §c. Cheap to keep
/// forever, and gives the price-history UI its data for free.
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

/// The dedup log. Without it the same drop would notify every day the sale lasts —
/// see Alerts/PriceDropDetector.swift for the once-per-level / re-arm rule.
struct PriceAlert: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var itemID: UUID
    var kind: AlertKind
    var priceFromCents: Int?
    var priceToCents: Int?
    var createdAt: Date = Date()
    var sentAt: Date?
}
