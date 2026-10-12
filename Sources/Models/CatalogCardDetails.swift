import Foundation

/// Shared presentation data for list and mural cards; canonical fields stay intact.
enum CatalogCardDetails {
    static func metadata(for item: Item) -> String {
        uniqueParts([item.store.displayName, item.variantDescription].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// Imported descriptions are separate from the short price-column metadata.
    static func subtitle(for item: Item) -> String? {
        guard let original = item.subtitle?.trimmedNonEmpty else { return nil }
        if let summary = item.summary?.trimmedNonEmpty, key(original) == key(summary) { return nil }
        let excluded = Set(uniqueParts([metadata(for: item), item.category].compactMap { $0 }).map(key))
        let text = uniqueParts([original]).filter { !excluded.contains(key($0)) }.joined(separator: " · ")
        guard !text.isEmpty else { return nil }
        if let summary = item.summary?.trimmedNonEmpty, key(text) == key(summary) { return nil }
        return text
    }

    private static func key(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func uniqueParts(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.flatMap { $0.components(separatedBy: "·") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !key($0).isEmpty && seen.insert(key($0)).inserted }
    }

    static func targetPrice(for item: Item) -> String? {
        item.targetPriceCents.map { "Obj. \(MoneyFormatter.string(cents: $0, currency: item.currency))" }
    }
}
