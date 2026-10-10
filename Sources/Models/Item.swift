import Foundation

/// The central entity. Prices are always integer cents, never `Double` — see
/// /tmp/opus_architecture.md §c for why (rounding, currency-safety).
struct Item: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var store: Store
    var storeItemID: String
    var region: String
    var currency: String
    var canonicalURL: URL
    var title: String
    var subtitle: String?
    var imageURL: URL?
    var category: String?
    var categorySource: CategorySource
    var storeGenre: String?
    var status: ItemStatus

    var priceCurrentCents: Int?
    var priceAtAddCents: Int?
    var priceReferenceCents: Int?
    var priceLowCents: Int?
    var priceLowAt: Date?
    var targetPriceCents: Int?
    /// The price level a drop/target alert already fired for. Cleared (re-armed)
    /// once the price rises back above it — see Alerts/PriceDropDetector.swift.
    var lastAlertedPriceCents: Int?
    var onSaleUntil: Date?

    var checkIntervalHours: Int
    var lastCheckedAt: Date?
    var lastSuccessAt: Date?
    var consecutiveFailures: Int
    var lastError: String?

    var externalIDs: [String: String]
    var tags: [String]?
    var notes: String?

    /// Short on-device summary of the store page (Apple Intelligence). Nil when
    /// the model is unavailable or the page offered no usable text.
    var summary: String?
    /// Selected variant, when the product has one ("M", "42", "256 GB"...).
    var size: String?
    var color: String?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        store: Store,
        storeItemID: String,
        region: String = "ES",
        currency: String = "EUR",
        canonicalURL: URL,
        title: String,
        subtitle: String? = nil,
        imageURL: URL? = nil,
        category: String? = nil,
        categorySource: CategorySource = .none,
        storeGenre: String? = nil,
        status: ItemStatus = .active,
        priceCurrentCents: Int? = nil,
        priceAtAddCents: Int? = nil,
        priceReferenceCents: Int? = nil,
        priceLowCents: Int? = nil,
        priceLowAt: Date? = nil,
        targetPriceCents: Int? = nil,
        lastAlertedPriceCents: Int? = nil,
        onSaleUntil: Date? = nil,
        checkIntervalHours: Int = 24,
        lastCheckedAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastError: String? = nil,
        externalIDs: [String: String] = [:],
        tags: [String]? = nil,
        notes: String? = nil,
        summary: String? = nil,
        size: String? = nil,
        color: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.store = store
        self.storeItemID = storeItemID
        self.region = region
        self.currency = currency
        self.canonicalURL = canonicalURL
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.category = category
        self.categorySource = categorySource
        self.storeGenre = storeGenre
        self.status = status
        self.priceCurrentCents = priceCurrentCents
        self.priceAtAddCents = priceAtAddCents
        self.priceReferenceCents = priceReferenceCents
        self.priceLowCents = priceLowCents
        self.priceLowAt = priceLowAt
        self.targetPriceCents = targetPriceCents
        self.lastAlertedPriceCents = lastAlertedPriceCents
        self.onSaleUntil = onSaleUntil
        self.checkIntervalHours = checkIntervalHours
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
        self.lastError = lastError
        self.externalIDs = externalIDs
        self.tags = tags
        self.notes = notes
        self.summary = summary
        self.size = size
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Identity key matching the architecture's `UNIQUE (store, store_item_id, region)`:
    /// adding the same URL twice becomes an idempotent no-op.
    var identityKey: String { "\(store.rawValue)|\(storeItemID)|\(region)" }

    var isStale: Bool { consecutiveFailures >= 3 }
}

extension Store {
    /// Stores for which we have a working price-fetch connector today.
    /// Generic and Amazon links capture metadata only when added. They are not
    /// periodically scraped, so they stay outside this set.
    static var refreshableStores: Set<Store> { [.appStore, .appleStore, .appleBooks, .appleMusic] }
}


extension Item {
    /// Historical comparison only. Neither persistence nor a lower reference price
    /// proves a promotion, or that a reduction is permanent. No time-based reset.
    var reductionSinceAddedCents: Int? {
        guard let current = priceCurrentCents, let initial = priceAtAddCents,
              current >= 0, initial > current else { return nil }
        return initial - current
    }
}


extension Item {
    /// "Talla M · Verde oliva" — only the parts that exist.
    var variantDescription: String? {
        let parts = [
            size.flatMap { $0.trimmedNonEmpty }.map { "Talla \($0)" },
            color.flatMap { $0.trimmedNonEmpty },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Builds a new catalog entry from a connector's one-time resolution.
    init(resolved: ResolvedItem, at date: Date = Date()) {
        self.init(
            store: resolved.store,
            storeItemID: resolved.storeItemID,
            region: resolved.region,
            currency: resolved.currency,
            canonicalURL: resolved.canonicalURL,
            title: resolved.title,
            subtitle: resolved.subtitle,
            imageURL: resolved.imageURL,
            category: resolved.storeGenre,
            categorySource: resolved.storeGenre == nil ? .none : .mapped,
            storeGenre: resolved.storeGenre,
            priceCurrentCents: resolved.priceCents,
            priceAtAddCents: resolved.priceCents,
            priceReferenceCents: resolved.priceReferenceCents,
            priceLowCents: resolved.priceCents,
            priceLowAt: resolved.priceCents != nil ? date : nil,
            lastCheckedAt: resolved.priceCents != nil ? date : nil,
            lastSuccessAt: resolved.priceCents != nil ? date : nil,
            size: resolved.size,
            color: resolved.color
        )
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
