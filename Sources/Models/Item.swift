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
    /// `amazon`, `eshop`, `psstore` and `generic` are modeled but not wired —
    /// see Connectors/ConnectorRegistry.swift.
    static var refreshableStores: Set<Store> { [.appStore, .appleBooks, .appleMusic] }
}
