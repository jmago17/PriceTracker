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
