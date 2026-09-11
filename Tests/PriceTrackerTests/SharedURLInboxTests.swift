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

    @Test func renderedCapturePersistsAndUpgradesDuplicateURL() throws {
        let (inbox, _) = makeInbox()
        let url = try #require(URL(string: "https://es.aliexpress.com/item/100500000000.html"))
        inbox.enqueue(url)

        let capture = SharedPageCapture(
            pageURLString: url.absoluteString,
            title: "Producto dinámico",
            imageURLString: "https://example.com/product.jpg",
            priceCents: 1_299,
            currency: "EUR"
        )
        inbox.enqueue(url, pageCapture: capture)

        let entries = inbox.load()
        #expect(entries.count == 1)
        #expect(entries[0].pageCapture == capture)
    }

    @Test func queueAndCaptchaPagesAreRejectedAsProductCaptures() throws {
        let requestedURL = try #require(URL(string: "https://store.nintendo.com/es-es/producto"))
        let queueCapture = SharedPageCapture(
            pageURLString: "https://nintendostoreuk.queue-it.net/?c=nintendostoreuk",
            title: "You are now in line"
        )
        let productCapture = SharedPageCapture(
            pageURLString: requestedURL.absoluteString,
            title: "The Legend of Zelda"
        )
        let captchaCapture = SharedPageCapture(
            pageURLString: requestedURL.absoluteString,
            title: "Verify you are human - CAPTCHA"
        )

        #expect(queueCapture.isLikelyAccessInterruption)
        #expect(captchaCapture.isLikelyAccessInterruption)
        #expect(!productCapture.isLikelyAccessInterruption)
    }
}
