import Foundation

/// Formats integer minor units using the item's actual ISO 4217 currency.
/// PriceTracker currently receives two-decimal prices from its connectors.
enum MoneyFormatter {
    static func string(cents: Int, currency: String, locale: Locale = Locale(identifier: "es_ES")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = NSDecimalNumber(value: Double(cents) / 100)
        return formatter.string(from: amount) ?? String(format: "%.2f %@", Double(cents) / 100, currency.uppercased())
    }
}
