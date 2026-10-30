import Foundation

struct MeResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var version: String?
    var items: Int?
    var serverTime: String?

    private enum CodingKeys: String, CodingKey { case ok, version, items, serverTime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        if let text = try? c.decodeIfPresent(String.self, forKey: .version) {
            version = text
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .version) {
            version = String(number)
        }
        items = try c.decodeIfPresent(Int.self, forKey: .items)
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
    }

    init(ok: Bool = true, version: String? = nil, items: Int? = nil, serverTime: String? = nil) {
        self.ok = ok; self.version = version; self.items = items; self.serverTime = serverTime
    }
}

struct ItemsResponse: Decodable, Sendable {
    /// Kept as the server wrote it: it is the next `since`, not a local date.
    var serverTime: String
    var full: Bool
    var items: [Item]
    var deleted: [UUID]

    private enum CodingKeys: String, CodingKey { case serverTime, full, items, deleted }

    init(serverTime: String, full: Bool, items: [Item], deleted: [UUID]) {
        self.serverTime = serverTime; self.full = full; self.items = items; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try c.decode(String.self, forKey: .serverTime)
        full = try c.decodeIfPresent(Bool.self, forKey: .full) ?? false
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        deleted = try c.decodeIfPresent([UUID].self, forKey: .deleted) ?? []
    }
}

struct ItemEnvelope: Decodable, Sendable {
    var item: Item
}

struct RefreshResponse: Decodable, Sendable {
    var deferred: Bool
    var why: String?
    var item: Item

    private enum CodingKeys: String, CodingKey { case deferred, why, item }

    init(deferred: Bool, why: String?, item: Item) {
        self.deferred = deferred; self.why = why; self.item = item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deferred = try c.decodeIfPresent(Bool.self, forKey: .deferred) ?? false
        why = try c.decodeIfPresent(String.self, forKey: .why)
        item = try c.decode(Item.self, forKey: .item)
    }
}

/// Wire shape of a history point. Tolerant on the optional parts so a missing
/// `itemID`/`currency` does not discard the whole history.
struct RemoteObservation: Decodable, Sendable {
    var id: UUID
    var itemID: UUID?
    var checkedAt: Date
    var priceCents: Int
    var currency: String?
    var isOnSale: Bool?
    var saleEndsAt: Date?
    var availability: String?

    func observation(for item: Item) -> PriceObservation {
        PriceObservation(
            id: id, itemID: item.id, checkedAt: checkedAt, priceCents: priceCents,
            currency: currency ?? item.currency, isOnSale: isOnSale ?? false,
            saleEndsAt: saleEndsAt, availability: availability
        )
    }
}

struct HistoryResponse: Decodable, Sendable {
    var observations: [RemoteObservation]
}

struct ServerErrorBody: Decodable, Sendable {
    var error: String?
}

/// Partial update for `PATCH /api/v1/items/:id`. Only fields marked `.set` or
/// `.clear` are sent; `.clear` is an explicit JSON `null`.
struct ItemPatch: Equatable, Sendable {
    enum Field<Value: Equatable & Sendable>: Equatable, Sendable {
        case unchanged
        case set(Value)
        case clear

        init(old: Value?, new: Value?) {
            if old == new { self = .unchanged }
            else if let new { self = .set(new) }
            else { self = .clear }
        }
    }

    var title: Field<String> = .unchanged
    var targetPriceCents: Field<Int> = .unchanged
    var tags: Field<[String]> = .unchanged
    var notes: Field<String> = .unchanged
    var category: Field<String> = .unchanged
    var size: Field<String> = .unchanged
    var color: Field<String> = .unchanged
    var summary: Field<String> = .unchanged
    var subtitle: Field<String> = .unchanged
    var status: Field<ItemStatus> = .unchanged

    var isEmpty: Bool { self == ItemPatch() }

    /// Differences the backend can store. Anything else (priority, local alert
    /// state, prices) is deliberately not part of the patch.
    static func diff(from old: Item, to new: Item) -> ItemPatch {
        var patch = ItemPatch()
        if old.title != new.title { patch.title = .set(new.title) }
        patch.targetPriceCents = Field(old: old.targetPriceCents, new: new.targetPriceCents)
        let oldTags = old.tags ?? [], newTags = new.tags ?? []
        if oldTags != newTags { patch.tags = newTags.isEmpty ? .clear : .set(newTags) }
        patch.notes = Field(old: old.notes, new: new.notes)
        patch.category = Field(old: old.category, new: new.category)
        patch.size = Field(old: old.size, new: new.size)
        patch.color = Field(old: old.color, new: new.color)
        patch.summary = Field(old: old.summary, new: new.summary)
        patch.subtitle = Field(old: old.subtitle, new: new.subtitle)
        if old.status != new.status, new.status == .archived || new.status == .active {
            patch.status = .set(new.status)
        }
        return patch
    }
}

extension ItemPatch: Encodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        func write<V: Encodable & Equatable & Sendable>(_ name: String, _ field: Field<V>) throws {
            switch field {
            case .unchanged: break
            case .set(let value): try c.encode(value, forKey: Key(name))
            case .clear: try c.encodeNil(forKey: Key(name))
            }
        }
        try write("title", title)
        try write("targetPriceCents", targetPriceCents)
        try write("tags", tags)
        try write("notes", notes)
        try write("category", category)
        try write("size", size)
        try write("color", color)
        try write("summary", summary)
        try write("subtitle", subtitle)
        try write("status", status)
    }
}
