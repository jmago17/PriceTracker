import Foundation

struct StorePageMetadata: Sendable {
    enum PriceKind: Sendable {
        case exact
        case from
    }

    var title: String
    var description: String?
    var sku: String?
    var currency: String?
    var priceCents: Int?
    var priceKind: PriceKind?
    var canonicalURL: URL
    var imageURL: URL?
}

struct StorePageLoader: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load(_ url: URL) async throws -> StorePageMetadata {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ConnectorError.network(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ConnectorError.network("La tienda respondió con HTTP \(httpResponse.statusCode)")
        }

        let finalURL = response.url ?? url
        guard let metadata = StorePageParser.parse(data: data, fallbackURL: finalURL) else {
            throw ConnectorError.decoding("La página no contiene metadatos utilizables")
        }
        return metadata
    }
}

enum StorePageParser {
    static func parse(data: Data, fallbackURL: URL) -> StorePageMetadata? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        let product = jsonLDProducts(in: html)
            .sorted { ($0.priceCents != nil ? 0 : 1) < ($1.priceCents != nil ? 0 : 1) }
            .first
        let meta = metaContents(in: html)

        guard let title = firstNonEmpty(
            product?.title,
            meta["og:title"],
            meta["twitter:title"],
            htmlTitle(in: html)
        ) else {
            return nil
        }

        let canonicalURL = resolved(product?.canonicalURL, relativeTo: fallbackURL)
            ?? resolved(meta["og:url"].flatMap(URL.init(string:)), relativeTo: fallbackURL)
            ?? resolved(canonicalLink(in: html), relativeTo: fallbackURL)
            ?? fallbackURL
        let metaPrice = number(meta["product:price:amount"] ?? meta["og:price:amount"])
        let currency = product?.currency
            ?? meta["product:price:currency"]
            ?? meta["og:price:currency"]
        let candidatePriceCents = product?.priceCents ?? metaPrice.map(cents)
        let priceCents = currency == nil ? nil : candidatePriceCents

        return StorePageMetadata(
            title: title,
            description: firstNonEmpty(product?.description, meta["og:description"], meta["description"]),
            sku: product?.sku,
            currency: currency,
            priceCents: priceCents,
            priceKind: product?.priceKind ?? (metaPrice == nil ? nil : .exact),
            canonicalURL: canonicalURL,
            imageURL: resolved(product?.imageURL, relativeTo: canonicalURL)
                ?? resolved(meta["og:image"].flatMap(URL.init(string:)), relativeTo: canonicalURL)
                ?? resolved(meta["twitter:image"].flatMap(URL.init(string:)), relativeTo: canonicalURL)
        )
    }

    private static func jsonLDProducts(in html: String) -> [StorePageMetadata] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*type\s*=\s*[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: fullRange).flatMap { match -> [StorePageMetadata] in
            guard let contentRange = Range(match.range(at: 1), in: html),
                  let jsonData = String(html[contentRange]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) else {
                return []
            }
            return productDictionaries(in: json).compactMap(parseJSONLDProduct)
        }
    }

    private static func productDictionaries(in value: Any) -> [[String: Any]] {
        if let values = value as? [Any] {
            return values.flatMap(productDictionaries)
        }
        guard let dictionary = value as? [String: Any] else { return [] }

        var products = typeContainsProduct(dictionary["@type"]) ? [dictionary] : []
        if let graph = dictionary["@graph"] {
            products.append(contentsOf: productDictionaries(in: graph))
        }
        return products
    }

    private static func typeContainsProduct(_ value: Any?) -> Bool {
        if let type = value as? String { return type == "Product" }
        if let types = value as? [String] { return types.contains("Product") }
        return false
    }

    private static func parseJSONLDProduct(_ dictionary: [String: Any]) -> StorePageMetadata? {
        guard let title = dictionary["name"] as? String else { return nil }

        let offerValue = dictionary["offers"]
        let offers: [[String: Any]]
        if let offer = offerValue as? [String: Any] {
            offers = [offer]
        } else {
            offers = offerValue as? [[String: Any]] ?? []
        }

        let exactOffer = offers.first { number($0["price"]) != nil }
        let aggregateOffer = offers.first { number($0["lowPrice"]) != nil }
        let selectedOffer = exactOffer ?? aggregateOffer
        let rawPrice = exactOffer.flatMap { number($0["price"]) }
            ?? aggregateOffer.flatMap { number($0["lowPrice"]) }
        let canonicalURL = (dictionary["url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "about:blank")!

        return StorePageMetadata(
            title: decodeHTMLEntities(title),
            description: (dictionary["description"] as? String).map(decodeHTMLEntities),
            sku: selectedOffer?["sku"] as? String ?? dictionary["sku"] as? String,
            currency: selectedOffer?["priceCurrency"] as? String,
            priceCents: rawPrice.map(cents),
            priceKind: exactOffer != nil ? .exact : (aggregateOffer != nil ? .from : nil),
            canonicalURL: canonicalURL,
            imageURL: imageURL(dictionary["image"])
        )
    }

    private static func metaContents(in html: String) -> [String: String] {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<meta\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return [:] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var contents: [String: String] = [:]
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[range]))
            guard let key = attributes["property"] ?? attributes["name"],
                  let content = attributes["content"] else { continue }
            contents[key.lowercased()] = decodeHTMLEntities(content)
        }
        return contents
    }

    private static func canonicalLink(in html: String) -> URL? {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<link\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[range]))
            guard attributes["rel"]?.lowercased().split(separator: " ").contains("canonical") == true,
                  let href = attributes["href"],
                  let url = URL(string: decodeHTMLEntities(href)) else { continue }
            return url
        }
        return nil
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*([\"'])(.*?)\2"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [:] }

        let fullRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var attributes: [String: String] = [:]
        for match in regex.matches(in: tag, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { continue }
            attributes[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
        }
        return attributes
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<title\b[^>]*>(.*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: fullRange),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return decodeHTMLEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private static func cents(_ price: Double) -> Int {
        Int((price * 100).rounded())
    }

    private static func imageURL(_ value: Any?) -> URL? {
        if let string = value as? String { return URL(string: decodeHTMLEntities(string)) }
        if let strings = value as? [String] {
            return strings.first.flatMap { URL(string: decodeHTMLEntities($0)) }
        }
        if let dictionary = value as? [String: Any],
           let string = dictionary["url"] as? String {
            return URL(string: decodeHTMLEntities(string))
        }
        return nil
    }

    private static func resolved(_ candidate: URL?, relativeTo baseURL: URL) -> URL? {
        guard let candidate, candidate.scheme != "about" else { return nil }
        if candidate.scheme != nil { return candidate }
        return URL(string: candidate.relativeString, relativeTo: baseURL)?.absoluteURL
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
