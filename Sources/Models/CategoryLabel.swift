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
        guard let label = semanticLabel(category) else { return "Sin categoría" }
        let words = label.split(whereSeparator: { $0.isWhitespace })
        return words.count <= 2 ? label : words.prefix(2).joined(separator: " ") + "…"
    }

    /// Ellipsis is presentation only, never a suggested canonical name.
    static func suggestion(_ category: String?) -> String? {
        guard let label = semanticLabel(category), wordCount(label) <= 2 else { return nil }
        return label
    }

    private static func semanticLabel(_ category: String?) -> String? {
        guard let category = category?.trimmedNonEmpty else { return nil }
        let normalized = category.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return aliases[normalized.lowercased()] ?? normalized
    }

    static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func allowsEdit(_ value: String, original: String?) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || wordCount(value) <= 2
    }
}
