import Foundation

/// Parses the "Precio mínimo" field of the Share sheet.
enum PriceInput {
    /// "12,50", "12.5", "1.234,56", "1,234.56" or "12 €" → cents. Empty text is
    /// no price (nil). Anything else that is not a positive amount throws.
    static func cents(from text: String) throws -> Int? {
        let invalid = PriceBucketError.validation("El precio mínimo no es válido. Escribe un importe como 49,99.")
        let cleaned = text.filter { !$0.isWhitespace && !"€$£".contains($0) }
        if cleaned.isEmpty { return nil }
        guard cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }) else { throw invalid }

        var integerPart = cleaned
        var fraction = ""
        if let last = cleaned.lastIndex(where: { $0 == "," || $0 == "." }) {
            let separator = cleaned[last]
            let before = String(cleaned[..<last])
            let after = String(cleaned[cleaned.index(after: last)...])
            let separatorCount = cleaned.filter { $0 == separator }.count
            let hasOtherKind = cleaned.contains { $0 != separator && ($0 == "," || $0 == ".") }
            // A lone separator followed by exactly three digits is a thousands
            // separator ("1.234"); a repeated one always is ("1.234.567").
            let isThousands = !hasOtherKind && (separatorCount > 1 || (after.count == 3 && !before.isEmpty && before.count <= 3))
            if isThousands {
                integerPart = cleaned.filter(\.isNumber)
            } else {
                guard separatorCount == 1 || hasOtherKind, after.count <= 2 else { throw invalid }
                integerPart = before.filter(\.isNumber)
                fraction = after
            }
        }
        guard integerPart.count <= 9, let whole = Int(integerPart.isEmpty ? "0" : integerPart) else { throw invalid }
        let cents = whole * 100 + (Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
        guard cents > 0 else {
            throw PriceBucketError.validation("El precio mínimo debe ser mayor que cero.")
        }
        return cents
    }
}

/// What the Share extension does with a link: send it straight to the server, or
/// park it in the App Group inbox when that is not possible right now. Kept free
/// of UI so it is testable with a fake transport.
struct ShareSubmission: Sendable {
    enum QueueReason: Equatable, Sendable {
        case notConfigured
        case offline
    }

    enum Outcome: Equatable, Sendable {
        /// Created on the server. `targetFailed` when the minimum price could
        /// not be stored afterwards.
        case added(targetFailed: Bool)
        case alreadyExists
        /// Saved in the inbox; the app sends it the next time it opens.
        case queued(QueueReason)

        var message: String {
            switch self {
            case .added(targetFailed: false): return "Añadido a tu lista"
            case .added(targetFailed: true): return "Añadido, pero no se pudo fijar el precio mínimo"
            case .alreadyExists: return "Ya estaba en tu lista"
            case .queued: return "Guardado, se enviará al abrir la app"
            }
        }
    }

    let settings: PriceBucketSettings
    let transport: any PriceBucketTransport
    let inbox: SharedURLInbox

    init(
        settings: PriceBucketSettings = PriceBucketSettings(),
        transport: any PriceBucketTransport = URLSessionTransport(),
        inbox: SharedURLInbox = SharedURLInbox()
    ) {
        self.settings = settings
        self.transport = transport
        self.inbox = inbox
    }

    /// - Throws: `PriceBucketError` when the server answers with an error that
    ///   retrying later would not fix (rejected key, invalid link, server fault),
    ///   or when the typed price is not a number.
    func submit(url: URL, minimumPriceText: String = "", sizeText: String = "") async throws -> Outcome {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw PriceBucketError.validation("Esa no es una URL válida.")
        }
        let target = try PriceInput.cents(from: minimumPriceText)
        let size = sizeText.trimmedNonEmpty

        guard settings.isConfigured else { return queue(url, size: size, target: target, reason: .notConfigured) }

        let settings = settings
        let client = PriceBucketClient(transport: transport, configuration: { try settings.configuration() })
        do {
            let item = try await client.addItem(url: url, size: size)
            guard let target else { return .added(targetFailed: false) }
            do {
                _ = try await client.patchItem(id: item.id, patch: ItemPatch(targetPriceCents: .set(target)))
                return .added(targetFailed: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .added(targetFailed: true)
            }
        } catch let error as PriceBucketError {
            if error.isAlreadyExists { return .alreadyExists }
            switch error {
            case .offline: return queue(url, size: size, target: target, reason: .offline)
            case .notConfigured: return queue(url, size: size, target: target, reason: .notConfigured)
            default: throw error
            }
        }
    }

    private func queue(_ url: URL, size: String?, target: Int?, reason: QueueReason) -> Outcome {
        inbox.enqueue(url, size: size, targetPriceCents: target)
        return .queued(reason)
    }
}
