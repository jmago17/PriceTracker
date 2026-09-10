import CloudKit
import Foundation

enum CloudRecordFields {
    static let identityKey = "identityKey"
    static let tombstone = "tombstone"
    static let itemID = "itemID"
    static let store = "store"
    static let storeItemID = "storeItemID"
    static let region = "region"
    static let currency = "currency"
    static let canonicalURL = "canonicalURL"
    static let title = "title"
    static let subtitle = "subtitle"
    static let imageURL = "imageURL"
    static let category = "category"
    static let categorySource = "categorySource"
    static let storeGenre = "storeGenre"
    static let status = "status"
    static let priceCurrentCents = "priceCurrentCents"
    static let priceAtAddCents = "priceAtAddCents"
    static let priceReferenceCents = "priceReferenceCents"
    static let priceLowCents = "priceLowCents"
    static let priceLowAt = "priceLowAt"
    static let targetPriceCents = "targetPriceCents"
    static let onSaleUntil = "onSaleUntil"
    static let checkIntervalHours = "checkIntervalHours"
    static let lastCheckedAt = "lastCheckedAt"
    static let lastSuccessAt = "lastSuccessAt"
    static let externalIDs = "externalIDs"
    static let tags = "tags"
    static let notes = "notes"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"

    static let itemFields = [
        itemID, store, storeItemID, region, currency, canonicalURL, title,
        subtitle, imageURL, category, categorySource, storeGenre, status,
        priceCurrentCents, priceAtAddCents, priceReferenceCents, priceLowCents,
        priceLowAt, targetPriceCents, onSaleUntil, checkIntervalHours,
        lastCheckedAt, lastSuccessAt, externalIDs, tags, notes, createdAt, updatedAt,
    ]
    static let all = [identityKey, tombstone] + itemFields
}

enum CloudRecordCodecError: Error, LocalizedError {
    case invalidRecord(String)
    case invalidSystemFields

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let field): return "Registro CloudKit inválido: falta o no es válido '\(field)'."
        case .invalidSystemFields: return "No se pudieron restaurar los system fields de CloudKit."
        }
    }
}

enum CloudRecordCodec {
    static let recordType = "CatalogItem"

    static func makeRecord(from local: LocalItemRecord, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let expectedID = CKRecord.ID(recordName: local.recordName, zoneID: zoneID)
        let record: CKRecord
        if let data = local.systemFields,
           let restored = try? self.record(fromSystemFields: data),
           restored.recordID == expectedID {
            record = restored
        } else {
            record = CKRecord(recordType: recordType, recordID: expectedID)
        }

        for key in CloudRecordFields.all { record[key] = nil }
        record[CloudRecordFields.identityKey] = local.identityKey as CKRecordValue
        record[CloudRecordFields.tombstone] = NSNumber(value: local.isTombstone)

        guard !local.isTombstone, let item = local.item else { return record }
        record[CloudRecordFields.itemID] = item.id.uuidString as CKRecordValue
        record[CloudRecordFields.store] = item.store.rawValue as CKRecordValue
        record[CloudRecordFields.storeItemID] = item.storeItemID as CKRecordValue
        record[CloudRecordFields.region] = item.region as CKRecordValue
        record[CloudRecordFields.currency] = item.currency as CKRecordValue
        record[CloudRecordFields.canonicalURL] = item.canonicalURL.absoluteString as CKRecordValue
        record[CloudRecordFields.title] = item.title as CKRecordValue
        set(item.subtitle, key: CloudRecordFields.subtitle, on: record)
        set(item.imageURL?.absoluteString, key: CloudRecordFields.imageURL, on: record)
        set(item.category, key: CloudRecordFields.category, on: record)
        record[CloudRecordFields.categorySource] = item.categorySource.rawValue as CKRecordValue
        set(item.storeGenre, key: CloudRecordFields.storeGenre, on: record)
        record[CloudRecordFields.status] = item.status.rawValue as CKRecordValue
        set(item.priceCurrentCents, key: CloudRecordFields.priceCurrentCents, on: record)
        set(item.priceAtAddCents, key: CloudRecordFields.priceAtAddCents, on: record)
        set(item.priceReferenceCents, key: CloudRecordFields.priceReferenceCents, on: record)
        set(item.priceLowCents, key: CloudRecordFields.priceLowCents, on: record)
        set(item.priceLowAt, key: CloudRecordFields.priceLowAt, on: record)
        set(item.targetPriceCents, key: CloudRecordFields.targetPriceCents, on: record)
        set(item.onSaleUntil, key: CloudRecordFields.onSaleUntil, on: record)
        record[CloudRecordFields.checkIntervalHours] = NSNumber(value: item.checkIntervalHours)
        set(item.lastCheckedAt, key: CloudRecordFields.lastCheckedAt, on: record)
        set(item.lastSuccessAt, key: CloudRecordFields.lastSuccessAt, on: record)
        record[CloudRecordFields.externalIDs] = try encoded(item.externalIDs) as CKRecordValue
        set(try item.tags.map(encoded), key: CloudRecordFields.tags, on: record)
        set(item.notes, key: CloudRecordFields.notes, on: record)
        record[CloudRecordFields.createdAt] = item.createdAt as CKRecordValue
        record[CloudRecordFields.updatedAt] = item.updatedAt as CKRecordValue
        return record
    }

    /// Device-local alert/error fields are deliberately preserved rather than
    /// read from CloudKit. They describe notification delivery and connector
    /// health on this device, not the shared catalog.
    static func item(from record: CKRecord, preservingDeviceFieldsFrom local: Item?) throws -> Item {
        guard let idString = string(record, CloudRecordFields.itemID),
              let id = UUID(uuidString: idString) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.itemID)
        }
        guard let storeRaw = string(record, CloudRecordFields.store),
              let store = Store(rawValue: storeRaw) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.store)
        }
        guard let storeItemID = string(record, CloudRecordFields.storeItemID) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.storeItemID)
        }
        guard let region = string(record, CloudRecordFields.region) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.region)
        }
        guard let currency = string(record, CloudRecordFields.currency) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.currency)
        }
        guard let urlString = string(record, CloudRecordFields.canonicalURL),
              let canonicalURL = URL(string: urlString) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.canonicalURL)
        }
        guard let title = string(record, CloudRecordFields.title) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.title)
        }

        let categorySource = string(record, CloudRecordFields.categorySource)
            .flatMap(CategorySource.init(rawValue:)) ?? .none
        let status = string(record, CloudRecordFields.status)
            .flatMap(ItemStatus.init(rawValue:)) ?? .active
        let externalIDs: [String: String] = try decodedData(
            record[CloudRecordFields.externalIDs],
            default: [:]
        )
        let tags: [String]? = try decodedOptionalData(record[CloudRecordFields.tags])

        return Item(
            id: id,
            store: store,
            storeItemID: storeItemID,
            region: region,
            currency: currency,
            canonicalURL: canonicalURL,
            title: title,
            subtitle: string(record, CloudRecordFields.subtitle),
            imageURL: string(record, CloudRecordFields.imageURL).flatMap(URL.init(string:)),
            category: string(record, CloudRecordFields.category),
            categorySource: categorySource,
            storeGenre: string(record, CloudRecordFields.storeGenre),
            status: status,
            priceCurrentCents: integer(record, CloudRecordFields.priceCurrentCents),
            priceAtAddCents: integer(record, CloudRecordFields.priceAtAddCents),
            priceReferenceCents: integer(record, CloudRecordFields.priceReferenceCents),
            priceLowCents: integer(record, CloudRecordFields.priceLowCents),
            priceLowAt: date(record, CloudRecordFields.priceLowAt),
            targetPriceCents: integer(record, CloudRecordFields.targetPriceCents),
            lastAlertedPriceCents: local?.lastAlertedPriceCents,
            onSaleUntil: date(record, CloudRecordFields.onSaleUntil),
            checkIntervalHours: integer(record, CloudRecordFields.checkIntervalHours) ?? 24,
            lastCheckedAt: date(record, CloudRecordFields.lastCheckedAt),
            lastSuccessAt: date(record, CloudRecordFields.lastSuccessAt),
            consecutiveFailures: local?.consecutiveFailures ?? 0,
            lastError: local?.lastError,
            externalIDs: externalIDs,
            tags: tags,
            notes: string(record, CloudRecordFields.notes),
            createdAt: date(record, CloudRecordFields.createdAt) ?? Date(),
            updatedAt: date(record, CloudRecordFields.updatedAt) ?? Date()
        )
    }

    static func isTombstone(_ record: CKRecord) -> Bool {
        (record[CloudRecordFields.tombstone] as? NSNumber)?.boolValue == true
    }

    static func identityKey(_ record: CKRecord) throws -> String {
        guard let value = string(record, CloudRecordFields.identityKey) else {
            throw CloudRecordCodecError.invalidRecord(CloudRecordFields.identityKey)
        }
        return value
    }

    static func matches(local: LocalItemRecord, serverRecord: CKRecord, zoneID: CKRecordZone.ID) throws -> Bool {
        let candidate = try makeRecord(
            from: LocalItemRecord(
                recordName: local.recordName,
                identityKey: local.identityKey,
                item: local.item,
                isTombstone: local.isTombstone,
                isDirty: local.isDirty,
                systemFields: nil
            ),
            zoneID: zoneID
        )
        return CloudRecordFields.all.allSatisfy {
            valuesEqual(candidate[$0], serverRecord[$0])
        }
    }

    /// Stores the accepted server record, including its user fields. Those
    /// fields are the ancestor required for a real three-way merge; preserving
    /// only the changeTag would not be enough to distinguish independent edits.
    static func archivedSystemFields(_ record: CKRecord) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
    }

    static func record(fromSystemFields data: Data) throws -> CKRecord {
        guard let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else {
            throw CloudRecordCodecError.invalidSystemFields
        }
        return record
    }

    static func copy(_ record: CKRecord) throws -> CKRecord {
        try self.record(fromSystemFields: archivedSystemFields(record))
    }

    static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (lhs?, rhs?):
            return (lhs as? NSObject)?.isEqual(rhs as? NSObject) == true
        }
    }

    private static func set(_ value: String?, key: String, on record: CKRecord) {
        record[key] = value.map { $0 as CKRecordValue }
    }

    private static func set(_ value: Int?, key: String, on record: CKRecord) {
        record[key] = value.map(NSNumber.init(value:))
    }

    private static func set(_ value: Date?, key: String, on record: CKRecord) {
        record[key] = value.map { $0 as CKRecordValue }
    }

    private static func set(_ value: Data?, key: String, on record: CKRecord) {
        record[key] = value.map { $0 as CKRecordValue }
    }

    private static func string(_ record: CKRecord, _ key: String) -> String? {
        record[key] as? String
    }

    private static func integer(_ record: CKRecord, _ key: String) -> Int? {
        (record[key] as? NSNumber)?.intValue
    }

    private static func date(_ record: CKRecord, _ key: String) -> Date? {
        record[key] as? Date
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decodedData<T: Decodable>(
        _ value: (any CKRecordValueProtocol)?,
        default defaultValue: T
    ) throws -> T {
        guard let data = value as? Data else { return defaultValue }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func decodedOptionalData<T: Decodable>(
        _ value: (any CKRecordValueProtocol)?
    ) throws -> T? {
        guard let data = value as? Data else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
