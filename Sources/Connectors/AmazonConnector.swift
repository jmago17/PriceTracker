import Foundation

/// Amazon items are never scraped periodically: Keepa already provides that
/// service. On add, the connector makes one best-effort metadata request so the
/// saved link can still include the title, image and visible price.
struct AmazonConnector: StoreConnector {
    let store: Store = .amazon

    private let loader: StorePageLoader

    init(session: URLSession = .shared) {
        loader = StorePageLoader(session: session)
    }

    func canResolve(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("amazon.") && Self.extractASIN(from: url) != nil
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        guard let asin = Self.extractASIN(from: url) else { throw ConnectorError.unrecognizedURL }
        let metadata = try? await loader.load(url)
        return ResolvedItem(
            store: .amazon,
            storeItemID: asin,
            region: "ES",
            currency: metadata?.currency ?? "EUR",
            canonicalURL: Self.canonicalURL(asin: asin, host: url.host ?? "www.amazon.es"),
            title: metadata?.title ?? "Amazon \(asin)",
            subtitle: metadata?.description,
            imageURL: metadata?.imageURL,
            priceCents: metadata?.priceCents,
            priceReferenceCents: nil,
            storeGenre: nil
        )
    }

    func fetch(_ item: Item) async throws -> FetchResult {
        throw ConnectorError.notSupported(
            "El seguimiento de precio de Amazon no está implementado (decisión de arquitectura: no se scrapea). Usa el enlace a Keepa."
        )
    }

    static func extractASIN(from url: URL) -> String? {
        let pattern = #"(?:dp|gp/product|gp/aw/d)/([A-Z0-9]{10})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let path = url.path
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, range: range),
              let asinRange = Range(match.range(at: 1), in: path) else { return nil }
        return String(path[asinRange])
    }

    static func canonicalURL(asin: String, host: String) -> URL {
        URL(string: "https://\(host)/dp/\(asin)") ?? URL(string: "https://www.amazon.es/dp/\(asin)")!
    }

    static func keepaURL(asin: String, domain: String = "com") -> URL {
        URL(string: "https://keepa.com/#!product/\(domain)-\(asin)")!
    }
}
