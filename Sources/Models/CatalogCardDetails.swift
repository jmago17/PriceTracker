import Foundation

/// Shared presentation data for list and mural cards; canonical fields stay intact.
enum CatalogCardDetails {
    static func metadata(for item: Item) -> String {
        let detail = item.variantDescription ?? item.category
        let candidates = [item.store.displayName, detail, item.subtitle].compactMap { $0 }
        var seen = Set<String>()
        return candidates.flatMap { $0.components(separatedBy: "·") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { part in
                let key = part.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
                return !key.isEmpty && seen.insert(key).inserted
            }
            .joined(separator: " · ")
    }

    static func targetPrice(for item: Item) -> String? {
        item.targetPriceCents.map { "Obj. \(MoneyFormatter.string(cents: $0, currency: item.currency))" }
    }
}
