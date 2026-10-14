import CloudKit
import Foundation
import Testing
@testable import PriceTracker

private let mergeZoneID = CKRecordZone.ID(
    zoneName: CloudRecordIdentity.zoneName,
    ownerName: CKCurrentUserDefaultName
)

private func mergeRecord(title: String, notes: String?) -> CKRecord {
    let record = CKRecord(
        recordType: CloudRecordCodec.recordType,
        recordID: CKRecord.ID(recordName: "item_test", zoneID: mergeZoneID)
    )
    record[CloudRecordFields.identityKey] = "appStore|1|ES" as CKRecordValue
    record[CloudRecordFields.tombstone] = NSNumber(value: false)
    record[CloudRecordFields.title] = title as CKRecordValue
    record[CloudRecordFields.notes] = notes.map { $0 as CKRecordValue }
    return record
}

private func codecItem(storeItemID: String, title: String) -> Item {
    Item(
        store: .appStore,
        storeItemID: storeItemID,
        canonicalURL: URL(string: "https://apps.apple.com/es/app/x/id\(storeItemID)")!,
        title: title
    )
}

struct CloudRecordMergerTests {
    @Test func independentConcurrentFieldEditsAreBothKept() throws {
        let ancestor = mergeRecord(title: "Old title", notes: "Old notes")
        let client = try CloudRecordCodec.copy(ancestor)
        client[CloudRecordFields.title] = "Client title" as CKRecordValue
        let server = try CloudRecordCodec.copy(ancestor)
        server[CloudRecordFields.notes] = "Server notes" as CKRecordValue

        let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)

        #expect(merged[CloudRecordFields.title] as? String == "Client title")
        #expect(merged[CloudRecordFields.notes] as? String == "Server notes")
    }

    @Test func sameFieldConflictUsesAcceptedServerValue() throws {
        let ancestor = mergeRecord(title: "Old", notes: nil)
        let client = try CloudRecordCodec.copy(ancestor)
        client[CloudRecordFields.title] = "Client" as CKRecordValue
        let server = try CloudRecordCodec.copy(ancestor)
        server[CloudRecordFields.title] = "Server" as CKRecordValue

        let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
        #expect(merged[CloudRecordFields.title] as? String == "Server")
    }

    @Test func concurrentTagEditsAreUnioned() throws {
        let ancestor = mergeRecord(title: "Item", notes: nil)
        ancestor[CloudRecordFields.tags] = try JSONEncoder().encode(["base"]) as CKRecordValue
        let client = try CloudRecordCodec.copy(ancestor)
        client[CloudRecordFields.tags] = try JSONEncoder().encode(["base", "client"]) as CKRecordValue
        let server = try CloudRecordCodec.copy(ancestor)
        server[CloudRecordFields.tags] = try JSONEncoder().encode(["base", "server"]) as CKRecordValue

        let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
        let data = try #require(merged[CloudRecordFields.tags] as? Data)
        let tags = try JSONDecoder().decode([String].self, from: data)
        #expect(tags == ["base", "client", "server"])
    }

    @Test func tombstoneWinsOverConcurrentEdit() throws {
        let ancestor = mergeRecord(title: "Old", notes: nil)
        let client = try CloudRecordCodec.copy(ancestor)
        client[CloudRecordFields.title] = "Edited" as CKRecordValue
        let server = try CloudRecordCodec.copy(ancestor)
        server[CloudRecordFields.tombstone] = NSNumber(value: true)

        let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
        #expect(CloudRecordCodec.isTombstone(merged))
        #expect(merged[CloudRecordFields.title] == nil)
    }

    @Test func codecRoundTripKeepsSharedFieldsAndPreservesDeviceFields() throws {
        var item = codecItem(storeItemID: "10", title: "Tagged")
        item.tags = ["games", "wishlist"]
        item.notes = "Shared note"
        item.lastAlertedPriceCents = 999
        item.lastError = "Local network error"
        item.consecutiveFailures = 2
        let local = LocalItemRecord(
            recordName: CloudRecordIdentity.recordName(for: item.identityKey),
            identityKey: item.identityKey,
            item: item,
            isTombstone: false,
            isDirty: true,
            systemFields: nil
        )

        let record = try CloudRecordCodec.makeRecord(from: local, zoneID: mergeZoneID)
        let archived = try CloudRecordCodec.archivedSystemFields(record)
        let ancestor = try CloudRecordCodec.record(fromSystemFields: archived)
        let decoded = try CloudRecordCodec.item(from: ancestor, preservingDeviceFieldsFrom: item)

        #expect(decoded.tags == item.tags)
        #expect(decoded.notes == item.notes)
        #expect(decoded.lastAlertedPriceCents == 999)
        #expect(decoded.lastError == "Local network error")
        #expect(decoded.consecutiveFailures == 2)
    }
}

extension CloudRecordMergerTests {
    @Test func priorityAndRiseStateRoundTripThroughExistingCloudSchema() throws {
        var item = codecItem(storeItemID: "priority", title: "Priority")
        item.priceAtAddCents = 1000
        item.priceCurrentCents = 1500
        item.priority = .high
        item.markInitialPriceRiseAlerted()
        let local = LocalItemRecord(recordName: "item_priority", identityKey: item.identityKey,
                                    item: item, isTombstone: false, isDirty: true, systemFields: nil)
        let record = try CloudRecordCodec.makeRecord(from: local, zoneID: mergeZoneID)
        var received = try CloudRecordCodec.item(from: record, preservingDeviceFieldsFrom: nil)
        #expect(received.priority == .high && received.hasAlertedInitialPriceRise)
        let didReset1 = received.useCurrentPriceAsInitial()
        #expect(didReset1)
        let reset = LocalItemRecord(recordName: "item_priority", identityKey: item.identityKey,
                                    item: received, isTombstone: false, isDirty: true, systemFields: nil)
        let resetRecord = try CloudRecordCodec.makeRecord(from: reset, zoneID: mergeZoneID)
        let synced = try CloudRecordCodec.item(from: resetRecord, preservingDeviceFieldsFrom: item)
        #expect(synced.priceAtAddCents == 1500 && !synced.hasAlertedInitialPriceRise)
        #expect(synced.priority == .high)
    }
}

extension CloudRecordMergerTests {
    @Test func priorityEditSurvivesConcurrentRiseMetadata() throws {
        let ancestor = mergeRecord(title: "Item", notes: nil)
        ancestor[CloudRecordFields.externalIDs] = try JSONEncoder().encode(["PriceTracker.priority": "normal"]) as CKRecordValue
        let client = try CloudRecordCodec.copy(ancestor)
        client[CloudRecordFields.externalIDs] = try JSONEncoder().encode(["PriceTracker.priority": "high"]) as CKRecordValue
        let server = try CloudRecordCodec.copy(ancestor)
        server[CloudRecordFields.externalIDs] = try JSONEncoder().encode([
            "PriceTracker.priority": "normal", "PriceTracker.alertedInitialPrice.EUR|1000|original": "true"
        ]) as CKRecordValue
        let result = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
        let values = try JSONDecoder().decode([String: String].self, from: #require(result[CloudRecordFields.externalIDs] as? Data))
        #expect(values["PriceTracker.priority"] == "high")
        #expect(values["PriceTracker.alertedInitialPrice.EUR|1000|original"] == "true")
    }
}
