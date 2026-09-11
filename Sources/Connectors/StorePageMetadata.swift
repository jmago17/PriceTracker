import Foundation

struct StorePageMetadata: Sendable {
    enum PriceKind: Sendable {
        case exact
        case from
    }

    var title: String
    var description: String?
    var sku: String?
    var category: String?
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
        request.setValue(Self.acceptLanguage(for: url), forHTTPHeaderField: "Accept-Language")
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
        if WebPageInterruptionDetector.isLikely(pageURL: finalURL, title: nil) {
            throw ConnectorError.network("La tienda ha mostrado una cola o comprobación de acceso")
        }
        guard let metadata = StorePageParser.parse(data: data, fallbackURL: finalURL) else {
            throw ConnectorError.decoding("La página no contiene metadatos utilizables")
        }
        if WebPageInterruptionDetector.isLikely(
            pageURL: finalURL,
            title: metadata.title,
            description: metadata.description
        ) {
            throw ConnectorError.network("La tienda ha mostrado una cola o comprobación de acceso")
        }
        return metadata
    }

    private static func acceptLanguage(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.hasPrefix("/es-es/") || path.hasPrefix("/es/es/") || url.host?.hasSuffix(".es") == true {
            return "es-ES,es;q=0.9"
        }
        return Locale.preferredLanguages.first ?? "en"
    }
}

enum StorePageParser {
    static func parse(data: Data, fallbackURL: URL) -> StorePageMetadata? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        let products = jsonLDProducts(in: html) + hydratedProducts(in: html)
        let product = products.first(where: { $0.priceCents != nil }) ?? products.first
        let meta = metaContents(in: html)
        let isAmazonPage = fallbackURL.host?.lowercased().contains("amazon.") == true
        let pageTitle = isAmazonPage
            ? firstNonEmpty(meta["title"], meta["og:title"], meta["twitter:title"], htmlTitle(in: html))
            : firstNonEmpty(meta["og:title"], meta["twitter:title"], meta["title"], htmlTitle(in: html))

        guard let title = firstNonEmpty(
            product?.title,
            pageTitle
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
            description: firstNonEmpty(
                product?.description,
                isAmazonPage ? meta["description"] : meta["og:description"],
                isAmazonPage ? meta["og:description"] : meta["description"]
            ),
            sku: product?.sku,
            category: product?.category,
            currency: currency,
            priceCents: priceCents,
            priceKind: product?.priceKind ?? (metaPrice == nil ? nil : .exact),
            canonicalURL: canonicalURL,
            imageURL: resolved(product?.imageURL, relativeTo: canonicalURL)
                ?? resolved(imageURLFromElement(withID: "landingImage", in: html), relativeTo: canonicalURL)
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

    /// Next.js and similar storefronts often serialize the product into a JSON
    /// hydration script instead of publishing JSON-LD. This stays schema-based:
    /// it looks for product-shaped objects rather than host names or CSS classes.
    private static func hydratedProducts(in html: String) -> [StorePageMetadata] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*id\s*=\s*[\"']__NEXT_DATA__[\"'][^>]*>(.*?)</script>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: fullRange).flatMap { match -> [StorePageMetadata] in
            guard let contentRange = Range(match.range(at: 1), in: html),
                  let jsonData = String(html[contentRange]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) else {
                return []
            }
            return hydratedProductDictionaries(in: json).compactMap(parseHydratedProduct)
        }
    }

    private static func hydratedProductDictionaries(in value: Any) -> [[String: Any]] {
        if let values = value as? [Any] {
            return values.flatMap(hydratedProductDictionaries)
        }
        guard let dictionary = value as? [String: Any] else { return [] }

        var products: [[String: Any]] = []
        if firstString(dictionary["name"] ?? dictionary["title"]) != nil,
           hydratedPrice(in: dictionary) != nil {
            products.append(dictionary)
        }
        for nested in dictionary.values where nested is [Any] || nested is [String: Any] {
            products.append(contentsOf: hydratedProductDictionaries(in: nested))
        }
        return products
    }

    private static func parseHydratedProduct(_ dictionary: [String: Any]) -> StorePageMetadata? {
        guard let title = firstString(dictionary["name"] ?? dictionary["title"]),
              let price = hydratedPrice(in: dictionary) else { return nil }

        let priceObject = dictionary["price"] as? [String: Any]
        let currency = firstString(
            dictionary["currency"]
                ?? dictionary["currencyCode"]
                ?? priceObject?["currencyCode"]
                ?? priceObject?["priceCurrency"]
        )
        let canonicalURL = firstString(dictionary["url"] ?? dictionary["path"])
            .flatMap(URL.init(string:))
            ?? URL(string: "about:blank")!

        return StorePageMetadata(
            title: decodeHTMLEntities(title),
            description: firstString(
                dictionary["description"]
                    ?? dictionary["shortDescription"]
                    ?? dictionary["longDescription"]
            ),
            sku: firstString(dictionary["sku"] ?? dictionary["id"]),
            category: firstString(dictionary["category"] ?? dictionary["primaryCategoryId"]),
            currency: currency,
            priceCents: currency == nil ? nil : cents(price),
            priceKind: .exact,
            canonicalURL: canonicalURL,
            imageURL: imageURL(dictionary["imageGroups"])
                ?? imageURL(dictionary["image"])
                ?? imageURL(dictionary["images"])
        )
    }

    private static func hydratedPrice(in dictionary: [String: Any]) -> Double? {
        if let price = number(dictionary["price"]) { return price }
        guard let price = dictionary["price"] as? [String: Any] else { return nil }
        return number(price["value"] ?? price["price"] ?? price["lowPrice"])
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
            category: firstString(dictionary["category"]),
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
        if let string = value as? String {
            let decoded = decodeHTMLEntities(string).trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.isEmpty ? nil : URL(string: decoded)
        }
        if let values = value as? [Any] {
            return values.lazy.compactMap(imageURL).first
        }
        if let dictionary = value as? [String: Any] {
            return imageURL(dictionary["contentUrl"] ?? dictionary["url"] ?? dictionary["link"])
                ?? imageURL(dictionary["images"])
                ?? imageURL(dictionary["imageGroups"])
        }
        return nil
    }

    private static func imageURLFromElement(withID id: String, in html: String) -> URL? {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[range]))
            guard attributes["id"]?.caseInsensitiveCompare(id) == .orderedSame else { continue }
            return imageURL(attributes["data-old-hires"] ?? attributes["src"])
        }
        return nil
    }

    private static func firstString(_ value: Any?) -> String? {
        if let string = value as? String {
            return firstNonEmpty(string).map(decodeHTMLEntities)
        }
        if let values = value as? [Any] {
            return values.lazy.compactMap(firstString).first
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
