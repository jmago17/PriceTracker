import Foundation

/// Amazon items are never scraped periodically: Keepa already provides that
/// service. On add, the connector makes one best-effort metadata request so the
/// saved link can still include the title, image and visible price.
struct AmazonConnector: StoreConnector {
    let store: Store = .amazon

    private let loader: StorePageLoader
    private let rendersDynamicPages: Bool

    init(session: URLSession = .shared, rendersDynamicPages: Bool = true) {
        loader = StorePageLoader(session: session)
        self.rendersDynamicPages = rendersDynamicPages
    }

    func canResolve(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("amazon.") && Self.extractASIN(from: url) != nil
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        try await resolve(url: url, pageCapture: nil)
    }

    func resolve(url: URL, pageCapture: SharedPageCapture?) async throws -> ResolvedItem {
        guard let asin = Self.extractASIN(from: url) else { throw ConnectorError.unrecognizedURL }
        let metadata = try? await loader.load(url)
        let renderedCapture: SharedPageCapture?
        if let pageCapture, !pageCapture.isLikelyAccessInterruption {
            renderedCapture = pageCapture
        } else if rendersDynamicPages {
            renderedCapture = try? await RenderedPageCaptureLoader().load(url)
        } else {
            renderedCapture = nil
        }

        let marketplace = Self.marketplace(for: url.host)
        let metadataTitle = Self.titleDetails(metadata?.title)
        let renderedTitle = Self.titleDetails(renderedCapture?.title)
        let title = renderedTitle.title ?? metadataTitle.title ?? "Amazon \(asin)"
        let description = renderedCapture?.description ?? metadata?.description
        let subtitle = description == title ? nil : description
        return ResolvedItem(
            store: .amazon,
            storeItemID: asin,
            region: marketplace.region,
            currency: renderedCapture?.currency ?? metadata?.currency ?? marketplace.currency,
            canonicalURL: Self.canonicalURL(asin: asin, host: url.host ?? "www.amazon.es"),
            title: title,
            subtitle: subtitle,
            imageURL: renderedCapture?.imageURL ?? metadata?.imageURL,
            priceCents: renderedCapture?.priceCents ?? metadata?.priceCents,
            priceReferenceCents: nil,
            storeGenre: renderedCapture?.category ?? metadata?.category ?? metadataTitle.category
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

    static func keepaURL(asin: String, region: String) -> URL {
        let domainID = switch region.uppercased() {
        case "GB": 2
        case "DE": 3
        case "FR": 4
        case "JP": 5
        case "CA": 6
        case "IT": 8
        case "ES": 9
        case "IN": 10
        case "MX": 11
        default: 1
        }
        return URL(string: "https://keepa.com/#!product/\(domainID)-\(asin)")!
    }

    private static func marketplace(for host: String?) -> (region: String, currency: String) {
        guard let host = host?.lowercased() else { return ("US", "USD") }
        if host.hasSuffix("amazon.co.uk") { return ("GB", "GBP") }
        if host.hasSuffix("amazon.de") { return ("DE", "EUR") }
        if host.hasSuffix("amazon.fr") { return ("FR", "EUR") }
        if host.hasSuffix("amazon.co.jp") { return ("JP", "JPY") }
        if host.hasSuffix("amazon.ca") { return ("CA", "CAD") }
        if host.hasSuffix("amazon.it") { return ("IT", "EUR") }
        if host.hasSuffix("amazon.es") { return ("ES", "EUR") }
        if host.hasSuffix("amazon.in") { return ("IN", "INR") }
        if host.hasSuffix("amazon.com.mx") { return ("MX", "MXN") }
        return ("US", "USD")
    }

    private static func titleDetails(_ title: String?) -> (title: String?, category: String?) {
        guard let title else { return (nil, nil) }
        guard let marker = title.range(of: " : Amazon.", options: [.caseInsensitive, .backwards]) else {
            return (title, nil)
        }

        let cleanTitle = title[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let marketplaceAndCategory = title[marker.upperBound...]
        let separator = marketplaceAndCategory.firstIndex(of: ":")
        let category = separator.map {
            marketplaceAndCategory[marketplaceAndCategory.index(after: $0)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cleanTitle.isEmpty ? title : cleanTitle, category?.isEmpty == false ? category : nil)
    }
}
