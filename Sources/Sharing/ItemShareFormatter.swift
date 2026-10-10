import Foundation

/// Plain-text form used when sharing catalog items: one bullet per item with
/// its name, the selected size and/or color when known, and the store link.
enum ItemShareFormatter {
    static func line(for item: Item) -> String {
        var parts = [item.title.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let variant = item.variantDescription {
            parts.append(variant)
        }
        parts.append(item.canonicalURL.absoluteString)
        return "• " + parts.joined(separator: " — ")
    }

    static func text(for items: [Item]) -> String {
        items.map(line(for:)).joined(separator: "\n")
    }

    /// Short message that accompanies a single shared link.
    static func message(for item: Item) -> String {
        [item.title, item.variantDescription].compactMap { $0 }.joined(separator: " — ")
    }
}
