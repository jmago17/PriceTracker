import Foundation

/// Display aliases never become filter keys or rewrite an existing category.
enum CategoryLabel {
    private static let aliases = [
        "hogar y cocina": "Hogar/Cocina",
        "deportes y aire libre": "Deporte exterior",
        "ropa, zapatos y joyería": "Moda",
        "salud y cuidado personal": "Cuidado personal",
        "herramientas y bricolaje": "Bricolaje",
        "oficina y papelería": "Papelería",
        "juegos y juguetes": "Juguetes",
        "accesorios para relojes": "Accesorios relojería",
        "correas para relojes": "Correas relojería"
    ]

    static func displayName(_ category: String?) -> String {
        guard let category = category?.trimmedNonEmpty else { return "Sin categoría" }
        let normalized = category.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return aliases[normalized.lowercased()] ?? normalized
    }

    static func displayName(_ category: String?, among categories: [String]) -> String {
        let label = displayName(category)
        if categories.contains(where: { $0 != category && displayName($0) == label }) {
            return category?.trimmedNonEmpty ?? label
        }
        return label
    }

    /// Do not invent an ambiguous category by taking its first two words.
    static func suggestion(_ category: String?) -> String? {
        guard category?.trimmedNonEmpty != nil else { return nil }
        let label = displayName(category)
        return wordCount(label) <= 2 ? label : nil
    }

    static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func allowsEdit(_ value: String, original: String?) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || wordCount(value) <= 2
    }
}
