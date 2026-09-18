import Testing
@testable import PriceTracker

struct MoneyFormatterTests {
    @Test func formatsUSDAmountWithDollarSymbol() {
        let value = MoneyFormatter.string(cents: 1299, currency: "USD")
        #expect(value.contains("$"))
        #expect(!value.contains("€"))
    }

    @Test func formatsEURAmountWithEuroSymbol() {
        let value = MoneyFormatter.string(cents: 1499, currency: "EUR")
        #expect(value.contains("€"))
        #expect(!value.contains("$"))
    }
}
