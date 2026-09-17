import Foundation

/// Visual QA caught "3 days ago" / "17 minutes ago" leaking through when the
/// simulator/device locale is English — the rest of the app's strings are
/// hardcoded Spanish, so relative dates must not follow system locale either.
extension Date {
    var relativeSpanish: String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: .now)
    }

    var shortTimeSpanish: String {
        Self.timeFormatter.string(from: self)
    }

    private static let spanishLocale = Locale(identifier: "es_ES")

    // Foundation's formatters aren't marked Sendable, but neither is mutated
    // after creation here — each is built once and only ever read from.
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = spanishLocale
        formatter.unitsStyle = .full
        return formatter
    }()

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = spanishLocale
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()
}
