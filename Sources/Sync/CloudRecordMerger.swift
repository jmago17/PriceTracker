import CloudKit
import Foundation

/// Three-way field merge. Independent edits survive; a server value wins when
/// both clients changed the same field. A tombstone always wins, independently
/// of device clocks, so stale devices cannot resurrect deleted items.
enum CloudRecordMerger {
    static func merge(ancestor: CKRecord?, client: CKRecord, server: CKRecord) throws -> CKRecord {
        let merged = try CloudRecordCodec.copy(server)

        if CloudRecordCodec.isTombstone(client) || CloudRecordCodec.isTombstone(server) {
            for key in CloudRecordFields.itemFields { merged[key] = nil }
            merged[CloudRecordFields.tombstone] = NSNumber(value: true)
            if merged[CloudRecordFields.identityKey] == nil {
                merged[CloudRecordFields.identityKey] = client[CloudRecordFields.identityKey]
            }
            return merged
        }

        let keys = Set(CloudRecordFields.all + client.allKeys() + server.allKeys() + (ancestor?.allKeys() ?? []))
        for key in keys {
            let ancestorValue = ancestor?[key]
            let clientValue = client[key]
            let serverValue = server[key]
            let clientChanged = !CloudRecordCodec.valuesEqual(clientValue, ancestorValue)
            let serverChanged = !CloudRecordCodec.valuesEqual(serverValue, ancestorValue)

            if clientChanged && !serverChanged {
                merged[key] = clientValue
            } else if clientChanged && serverChanged {
                _ = mergeCollectionField(
                    key: key,
                    clientValue: clientValue,
                    serverValue: serverValue,
                    into: merged
                )
            }
            // Collection fields merge their independent members. Any other
            // same-field conflict retains CloudKit's accepted server value,
            // never a local timestamp.
        }
        return merged
    }

    private static func mergeCollectionField(
        key: String,
        clientValue: Any?,
        serverValue: Any?,
        into record: CKRecord
    ) -> Bool {
        guard let clientData = clientValue as? Data,
              let serverData = serverValue as? Data else { return false }

        if key == CloudRecordFields.tags,
           let client = try? JSONDecoder().decode([String].self, from: clientData),
           let server = try? JSONDecoder().decode([String].self, from: serverData),
           let data = try? JSONEncoder().encode(Array(Set(client + server)).sorted()) {
            record[key] = data as CKRecordValue
            return true
        }

        if key == CloudRecordFields.externalIDs,
           let client = try? JSONDecoder().decode([String: String].self, from: clientData),
           let server = try? JSONDecoder().decode([String: String].self, from: serverData) {
            let combined = client.merging(server) { _, serverValue in serverValue }
            if let data = try? JSONEncoder().encode(combined) {
                record[key] = data as CKRecordValue
                return true
            }
        }
        return false
    }
}
