import Foundation
import Testing
@testable import PriceTracker

struct CatalogPriceCheckTests {
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_003_600)

    private func item(success: Date? = nil) -> Item {
        Item(store: .appStore, storeItemID: UUID().uuidString,
             canonicalURL: URL(string: "https://example.com/item")!, title: "Producto",
             priceCurrentCents: 1299, priceAtAddCents: 1299,
             priceLowCents: 1299, priceLowAt: success,
             lastCheckedAt: success, lastSuccessAt: success)
    }

    @Test func noSuccessDoesNotInventADateFromAttemptsOrEdits() {
        var unchecked = item()
        unchecked.lastCheckedAt = later
        unchecked.lastError = "Sin conexión"
        unchecked.updatedAt = later
        #expect(CatalogPriceCheck.latestSuccess(in: []) == nil)
        #expect(CatalogPriceCheck.latestSuccess(in: [unchecked]) == nil)
    }

    @Test func samePriceSuccessAdvancesTimestamp() {
        let original = item(success: first)
        let fetch = FetchResult(priceCents: 1299, currency: "EUR", isOnSale: false, availability: "available")
        let refreshed = PriceDropDetector.evaluate(item: original, fetch: fetch, now: later).updatedItem
        #expect(refreshed.priceCurrentCents == original.priceCurrentCents)
        #expect(refreshed.priceLowAt == first)
        #expect(CatalogPriceCheck.latestSuccess(in: [refreshed]) == later)
    }

    @Test func failedOrPartialRefreshDoesNotPretendToBeAFullSuccessfulBatch() {
        enum Offline: Error { case unavailable }
        let original = item(success: first)
        let failed = PriceDropDetector.applyFailure(to: original, error: Offline.unavailable, now: later)
        #expect(failed.lastCheckedAt == later)
        #expect(CatalogPriceCheck.latestSuccess(in: [failed]) == first)
        let successfulSubset = item(success: later)
        let laterFailure = PriceDropDetector.applyFailure(to: successfulSubset, error: Offline.unavailable, now: later.addingTimeInterval(60))
        #expect(CatalogPriceCheck.latestSuccess(in: [failed, laterFailure, item()]) == later)
        #expect(failed.lastSuccessAt == first) // Other items were not refreshed successfully.
    }

    @Test func catalogDataSurvivesReloadAndIncludesPausedItems() throws {
        var active = item(success: first)
        active.updatedAt = later.addingTimeInterval(10_000)
        active.title = "Nombre editado"
        var paused = item(success: later)
        paused.status = .archived
        paused.category = "Otra categoría"
        let stored = [active, paused]
        let loaded = try JSONDecoder().decode([Item].self, from: JSONEncoder().encode(stored))
        #expect(CatalogPriceCheck.latestSuccess(in: loaded) == later)
        #expect(CatalogPriceCheck.latestSuccess(in: [active]) == first)
    }

    @Test func formattingFollowsLocaleAndTimeZoneAcrossMidnight() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 0, minute: 30)))
        let spanish = Locale(identifier: "es_ES")
        let eastern = CatalogPriceCheck.formatted(date, locale: spanish, calendar: calendar, timeZone: newYork)
        let previousDayUTC = CatalogPriceCheck.formatted(date.addingTimeInterval(-5 * 3600), locale: spanish, calendar: calendar, timeZone: utc)
        #expect(eastern == previousDayUTC)
        #expect(eastern.contains("19:30"))
        #expect(eastern.contains("2026"))
        let american = CatalogPriceCheck.formatted(date, locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: newYork)
        #expect(american != eastern)
        #expect(american.contains("7:30"))
        #expect(american.contains("PM"))
    }
}
