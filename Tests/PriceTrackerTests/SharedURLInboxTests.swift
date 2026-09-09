import Foundation
import Testing
@testable import PriceTracker

struct SharedURLInboxTests {
    private func makeInbox() -> (SharedURLInbox, UserDefaults) {
        let suite = "PriceTrackerTests.Inbox.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SharedURLInbox(defaults: defaults), defaults)
    }

    @Test func enqueuePersistsAndDeduplicatesURL() {
        let (inbox, _) = makeInbox()
        let url = URL(string: "https://apps.apple.com/us/app/clash-royale/id1053012308")!
        inbox.enqueue(url)
        inbox.enqueue(url)
        #expect(inbox.load().count == 1)
        #expect(inbox.load().first?.urlString == url.absoluteString)
    }

    @Test func failedEntryIsRetainedAndCanBeRemoved() {
        let (inbox, _) = makeInbox()
        inbox.enqueue(URL(string: "https://example.com/product")!)
        let entry = inbox.load()[0]
        inbox.markFailed(id: entry.id, error: "Unsupported")
        #expect(inbox.load()[0].lastError == "Unsupported")
        #expect(inbox.load()[0].attempts == 1)
        inbox.remove(id: entry.id)
        #expect(inbox.load().isEmpty)
    }
}
