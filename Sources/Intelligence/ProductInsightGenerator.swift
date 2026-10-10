import Foundation
import FoundationModels

/// What the on-device model adds to a ficha. Size and color are only
/// suggestions for items whose page did not expose them in structured data.
struct ProductInsight: Sendable, Equatable {
    var summary: String?
    var size: String?
    var color: String?
}

@Generable
struct GeneratedProductInsight {
    @Guide(description: "Resumen en español del producto, de dos o tres frases y como máximo 60 palabras. Describe qué es, sus características y materiales más relevantes y cualquier consejo de talla o compatibilidad que aparezca en la página. No menciones el precio, ofertas, envíos, la tienda ni valoraciones.")
    var summary: String

    @Guide(description: "Talla, tamaño o capacidad de la variante seleccionada en la página, tal como aparece (por ejemplo «M», «42», «256 GB»). Déjalo vacío si la página no muestra una variante elegida o el producto no tiene tallas.")
    var size: String?

    @Guide(description: "Color de la variante seleccionada en la página, en español y con mayúscula inicial (por ejemplo «Azul marino»). Déjalo vacío si no hay un color elegido o el producto no tiene variantes de color.")
    var color: String?
}

enum ProductInsightError: Error, LocalizedError {
    case unavailable(String)
    case noText
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .noText: return "La página no tiene texto suficiente para resumir."
        case .generation(let message): return "Apple Intelligence no pudo generar el resumen: \(message)"
        }
    }
}

/// Summarizes scraped page text with Apple Intelligence (Foundation Models),
/// entirely on device. Nothing is sent to a server.
struct ProductInsightGenerator: Sendable {
    /// The on-device model has a small context window (≈4K tokens shared by
    /// instructions, prompt and answer), so page text is trimmed beforehand.
    private static let promptCharacterBudgets = [6_000, 2_500]

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Este dispositivo no es compatible con Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Activa Apple Intelligence en Ajustes para generar resúmenes."
        case .unavailable(.modelNotReady):
            return "El modelo de Apple Intelligence todavía se está descargando."
        case .unavailable:
            return "Apple Intelligence no está disponible ahora mismo."
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    func insight(
        title: String,
        storeName: String,
        url: URL,
        pageText: String
    ) async throws -> ProductInsight {
        if let reason = Self.unavailableReason {
            throw ProductInsightError.unavailable(reason)
        }
        let cleaned = Self.cleaned(pageText)
        guard cleaned.count >= 40 else { throw ProductInsightError.noText }

        var lastError: Error = ProductInsightError.noText
        for budget in Self.promptCharacterBudgets {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(
                    to: Self.prompt(title: title, storeName: storeName, url: url, text: String(cleaned.prefix(budget))),
                    generating: GeneratedProductInsight.self,
                    options: GenerationOptions(temperature: 0.2)
                )
                let generated = response.content
                return ProductInsight(
                    summary: generated.summary.trimmedNonEmpty,
                    size: generated.size.flatMap(Self.cleanVariant),
                    color: generated.color.flatMap(Self.cleanVariant)
                )
            } catch let error as LanguageModelSession.GenerationError {
                lastError = error
                if case .exceededContextWindowSize = error { continue }
                throw ProductInsightError.generation(error.localizedDescription)
            }
        }
        throw ProductInsightError.generation(lastError.localizedDescription)
    }

    private static let instructions = """
    Eres un asistente que lee el texto de la ficha de un producto en una tienda online \
    y escribe un resumen breve, neutro y factual en español. Usa solo información que \
    aparezca en el texto; si algo no está, no lo inventes. Ignora menús, cookies, \
    enlaces legales, recomendaciones de otros productos y opiniones de clientes.
    """

    private static func prompt(title: String, storeName: String, url: URL, text: String) -> String {
        """
        Producto: \(title)
        Tienda: \(storeName)
        Enlace: \(url.absoluteString)

        Texto de la página:
        \(text)
        """
    }

    /// Drops very short lines (menu items, buttons) and duplicate lines that
    /// would otherwise eat the model's small context window.
    static func cleaned(_ text: String) -> String {
        var seen = Set<String>()
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard line.count >= 3, line.split(separator: " ").count >= 2 || line.count >= 20 else { return false }
                return seen.insert(line.lowercased()).inserted
            }
            .joined(separator: "\n")
    }

    private static func cleanVariant(_ value: String) -> String? {
        guard let trimmed = value.trimmedNonEmpty, trimmed.count <= 40 else { return nil }
        let placeholders = ["n/a", "ninguno", "ninguna", "no aplica", "desconocido", "-", "—", "null", "nil"]
        return placeholders.contains(trimmed.lowercased()) ? nil : trimmed
    }
}

/// Fills `summary` (and missing size/color) after an item is saved. Runs in
/// the app only; failures leave the item untouched.
struct ItemEnricher: Sendable {
    let itemStore: any PriceHistoryStoring
    let connectors: ConnectorRegistry
    var generator = ProductInsightGenerator()

    /// - Parameters:
    ///   - pageText: text captured while adding. When nil, the page is read again.
    /// - Returns: the stored item with its new summary.
    func enrich(_ item: Item, pageText: String?) async throws -> Item {
        var text = pageText
        var resolvedSize: String?
        var resolvedColor: String?
        if text?.trimmedNonEmpty == nil {
            let resolved = try? await connectors.resolve(url: item.canonicalURL)
            text = resolved?.pageText
            resolvedSize = resolved?.size
            resolvedColor = resolved?.color
        }
        let fallback = [item.title, item.subtitle].compactMap { $0 }.joined(separator: "\n")
        let source = text?.trimmedNonEmpty ?? fallback

        let insight = try await generator.insight(
            title: item.title,
            storeName: item.store.displayName,
            url: item.canonicalURL,
            pageText: source
        )

        // Re-read so a concurrent edit or refresh is not overwritten.
        var current = try await itemStore.item(id: item.id) ?? item
        current.summary = insight.summary ?? current.summary
        if current.size?.trimmedNonEmpty == nil { current.size = resolvedSize ?? insight.size }
        if current.color?.trimmedNonEmpty == nil { current.color = resolvedColor ?? insight.color }
        current.updatedAt = Date()
        return try await itemStore.upsert(current)
    }
}
