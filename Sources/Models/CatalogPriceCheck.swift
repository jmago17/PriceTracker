import Foundation

/// Latest successful price check among items currently in the catalog. This is
/// not a batch-completion timestamp: a partial refresh can advance it too.
/// lastCheckedAt includes failures; updatedAt includes unrelated metadata edits.
enum CatalogPriceCheck {
    static func latestSuccess(in items: [Item]) -> Date? {
        items.compactMap(\.lastSuccessAt).max()
    }

    static func formatted(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        Date.FormatStyle(date: .abbreviated, time: .shortened,
                         locale: locale, calendar: calendar, timeZone: timeZone)
            .format(date)
    }
}
