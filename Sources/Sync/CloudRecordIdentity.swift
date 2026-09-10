import CryptoKit
import Foundation

enum CloudRecordIdentity {
    static let containerIdentifier = "iCloud.com.maromeapps.PriceTracker"
    static let zoneName = "PriceTrackerCatalog"

    static func recordName(for identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.utf8))
        return "item_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
