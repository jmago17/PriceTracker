import Testing
@testable import PriceTracker

struct CloudRecordIdentityTests {
    @Test func deterministicNameUsesWholeLogicalIdentity() {
        let identity = "appStore|1053012308|ES"
        let first = CloudRecordIdentity.recordName(for: identity)
        let second = CloudRecordIdentity.recordName(for: identity)

        #expect(first == second)
        #expect(first.hasPrefix("item_"))
        #expect(first.count == 69)
        #expect(first != CloudRecordIdentity.recordName(for: "appStore|1053012308|US"))
    }
}
