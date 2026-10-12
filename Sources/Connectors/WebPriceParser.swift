import Foundation
import CoreFoundation

/// Strict refresh extraction. The permissive add-time parser is never trusted
/// to choose a price: related products, ranges and unverified variants fail closed.
enum WebPriceParser {
    static func parse(data: Data, finalURL: URL, item: Item) throws -> FetchResult {
        guard let html = String(data: data, encoding: .utf8), html.count <= 2_000_000 else { throw WebPriceError.missing }
        let document = PriceHTML.parse(html)
        let visible = document.text.lowercased()
        let blocked = ["robot check", "validatecaptcha", "enter the characters you see", "introduce los caracteres", "verify you are human", "verifica que eres humano", "sign in to see price", "inicia sesión para ver el precio", "access denied"]
        let loginPaths = ["/ap/signin", "/login", "/account/login", "/signin"]
        if loginPaths.contains(where: { finalURL.path.lowercased().hasPrefix($0) }) || WebPageInterruptionDetector.isLikely(pageURL: finalURL, title: document.nodes.first { $0.tag == "title" }?.text)
            || blocked.contains(where: visible.contains)
            || document.nodes.contains(where: { ($0.attributes["action"] ?? "").lowercased().contains("validatecaptcha") || ($0.attributes["src"] ?? "").lowercased().contains("captcha") }) {
            throw WebPriceError.blocked
        }
        guard !(item.canonicalURL.scheme == "https" && finalURL.scheme != "https"),
              sameHost(finalURL, item.canonicalURL) else { throw WebPriceError.identity }
        let canonical = document.nodes.first { $0.tag == "link" && $0.attributes["rel"] == "canonical" }
            .flatMap { absolute($0.attributes["href"], base: finalURL) }
        guard matches(finalURL, item: item) || canonical.map({ matches($0, item: item) }) == true else { throw WebPriceError.identity }

        let scripts = document.nodes.filter { $0.tag == "script" && $0.attributes["type"]?.lowercased() == "application/ld+json" }
        var products: [[String: Any]] = []
        var graph: [String: [String: Any]] = [:]
        for script in scripts {
            guard let bytes = script.rawText.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: bytes) else { continue }
            collect(json, products: &products, graph: &graph)
        }
        if !products.isEmpty {
            let selected = products.filter { product in
                if let url = absolute(string(product["url"]), base: finalURL) { return matches(url, item: item) }
                if item.store == .amazon, string(product["sku"]) == item.storeItemID { return true }
                return products.count == 1 && normalized(string(product["name"]) ?? "") == normalized(item.title)
            }
            guard !selected.isEmpty else { throw WebPriceError.identity }
            let results = try selected.map { product -> FetchResult in
                if item.store == .amazon, let sku = string(product["sku"]), sku != item.storeItemID { throw WebPriceError.identity }
                try validateVariant(size: string(product["size"]), color: string(product["color"]), item: item,
                    asinBound: item.store == .amazon && (string(product["sku"]) == item.storeItemID || absolute(string(product["url"]), base: finalURL).map { matches($0, item: item) } == true))
                let offers = dictionaries(product["offers"]).map { resolve($0, graph: graph) }
                guard !offers.isEmpty else { throw WebPriceError.missing }
                let prices = try offers.map { try offer($0, base: finalURL, item: item) }
                return try unique(prices)
            }
            return try unique(results)
        }

        let microProducts = document.nodes.filter { schemaType($0.attributes["itemtype"]) == "Product" }
        if !microProducts.isEmpty {
            let selected = microProducts.filter { node in
                let values = properties(node)
                if let url = absolute(values["url"]?.first, base: finalURL) { return matches(url, item: item) }
                return microProducts.count == 1 && normalized(values["name"]?.first ?? "") == normalized(item.title)
            }
            guard selected.count == 1, let product = selected.first else { throw WebPriceError.identity }
            let values = properties(product)
            try validateVariant(size: values["size"]?.first, color: values["color"]?.first, item: item, asinBound: false)
            let offers = product.nodes.filter { schemaType($0.attributes["itemtype"]) == "Offer" && nearestProduct($0) === product }
            guard !offers.isEmpty else { throw WebPriceError.missing }
            return try unique(offers.map { node in
                let props = properties(node)
                guard props["price"]?.count == 1, props["priceCurrency"]?.count == 1,
                      !node.nodes.contains(where: {
                          schemaType($0.attributes["itemtype"]) == "UnitPriceSpecification"
                              || ["eligibleQuantity", "eligibleTransactionVolume", "eligibleCustomerType", "validForMemberTier", "priceSpecification"].contains($0.attributes["itemprop"] ?? "")
                      }) else { throw WebPriceError.ambiguous }
                var dictionary: [String: Any] = [:]
                for (key, value) in props { if let first = value.first { dictionary[key] = first } }
                return try offer(dictionary, base: finalURL, item: item)
            })
        }

        if item.store == .amazon { return try amazon(document, item: item) }
        // Page-level metadata is admissible only when explicitly bound to this
        // product URL, with no unresolved variant and no structured products.
        let meta = metadata(document)
        guard meta["og:type"] == ["product"],
              let url = absolute(meta["og:url"]?.first, base: finalURL), matches(url, item: item) else { throw WebPriceError.missing }
        try validateVariant(size: nil, color: nil, item: item, asinBound: false)
        let amounts = meta["product:price:amount"] ?? meta["og:price:amount"] ?? []
        let currencies = meta["product:price:currency"] ?? meta["og:price:currency"] ?? []
        guard Set(amounts).count == 1, Set(currencies).count == 1, let amount = amounts.first, let currency = currencies.first else { throw WebPriceError.ambiguous }
        return try result(amount: amount, currency: currency, item: item)
    }

    private static func offer(_ offer: [String: Any], base: URL, item: Item) throws -> FetchResult {
        let types = (offer["@type"] as? [String] ?? [string(offer["@type"]) ?? "Offer"]).compactMap(schemaType)
        guard types.contains("Offer"), !types.contains("AggregateOffer"), offer["lowPrice"] == nil, offer["highPrice"] == nil,
              offer["priceSpecification"] == nil,
              ["billingDuration", "billingIncrement", "referenceQuantity", "unitCode", "eligibleQuantity", "eligibleTransactionVolume", "eligibleCustomerType", "validForMemberTier"].allSatisfy({ offer[$0] == nil }) else { throw WebPriceError.ambiguous }
        if let region = offer["eligibleRegion"] {
            let regions = (region as? [String]) ?? string(region).map { [$0] } ?? []
            guard regions.map({ $0.uppercased() }).contains(item.region.uppercased()) else { throw WebPriceError.ambiguous }
        }
        if let function = string(offer["businessFunction"]), schemaType(function) != "Sell" { throw WebPriceError.ambiguous }
        if let condition = string(offer["itemCondition"]), schemaType(condition) != "NewCondition" { throw WebPriceError.ambiguous }
        if let availability = string(offer["availability"]), !["InStock", "LimitedAvailability", "PreOrder", "BackOrder", "OnlineOnly"].contains(schemaType(availability) ?? "") { throw WebPriceError.missing }
        if let end = string(offer["priceValidUntil"]), let date = ISO8601DateFormatter().date(from: end.count == 10 ? end + "T23:59:59Z" : end), date < Date() { throw WebPriceError.missing }
        if let url = absolute(string(offer["url"]), base: base), !matches(url, item: item) { throw WebPriceError.variant }
        guard let amount = string(offer["price"]), let currency = string(offer["priceCurrency"]) else { throw WebPriceError.missing }
        var value = try result(amount: amount, currency: currency, item: item)
        value.availability = string(offer["availability"]).flatMap(schemaType) ?? "unknown"
        return value
    }

    private static func result(amount: String, currency: String, item: Item) throws -> FetchResult {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code == item.currency.uppercased(), Locale.commonISOCurrencyCodes.contains(code) else { throw WebPriceError.currency }
        guard let cents = cents(amount) else { throw WebPriceError.ambiguous }
        return FetchResult(priceCents: cents, currency: code, isOnSale: false, availability: "unknown")
    }

    /// Decimal arithmetic, not binary rounding; schema values cannot contain
    /// currency signs, grouping, exponents, ranges or more than two decimals.
    static func cents(_ amount: String) -> Int? {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d{1,10}(?:\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: value * 100).intValue
    }

    private static func unique(_ values: [FetchResult]) throws -> FetchResult {
        guard let first = values.first else { throw WebPriceError.missing }
        guard values.allSatisfy({ $0.priceCents == first.priceCents && $0.currency == first.currency }) else { throw WebPriceError.ambiguous }
        return first
    }

    private static func validateVariant(size: String?, color: String?, item: Item, asinBound: Bool) throws {
        for (expected, actual) in [(item.size, size), (item.color, color)] {
            guard let expected = expected?.trimmedNonEmpty else { continue }
            if let actual { guard normalized(expected) == normalized(actual) else { throw WebPriceError.variant } }
            else if !asinBound { throw WebPriceError.variant }
        }
    }

    private static func amazon(_ document: PriceHTML, item: Item) throws -> FetchResult {
        let selectedASINs = Set(document.nodes.filter {
            $0.tag == "input" && ($0.attributes["id"] == "ASIN" || $0.attributes["name"] == "ASIN")
        }.compactMap { $0.attributes["value"] }.filter { !$0.isEmpty })
        guard selectedASINs == [item.storeItemID],
              document.nodes.contains(where: { $0.attributes["id"] == "productTitle" && !$0.text.isEmpty }) else { throw WebPriceError.identity }
        // Amazon's selected ASIN identifies the chosen child variant. Any explicit
        // selected values we can see must still match the user's stored variant.
        for (id, expected) in [("variation_size_name", item.size), ("variation_color_name", item.color)] {
            if let expected, let section = document.nodes.first(where: { $0.attributes["id"] == id }),
               let selection = section.nodes.first(where: { $0.classes.contains("selection") }),
               normalized(selection.text) != normalized(expected) { throw WebPriceError.variant }
        }
        if let availability = document.nodes.first(where: { $0.attributes["id"] == "availability" })?.text.lowercased(),
           ["currently unavailable", "temporarily out", "no disponible", "agotado", "indisponible"].contains(where: availability.contains) {
            throw WebPriceError.missing
        }
        let blockIDs = ["corePriceDisplay_desktop_feature_div", "corePrice_feature_div", "apex_desktop", "priceblock_ourprice", "priceblock_dealprice"]
        let blocks = document.nodes.filter { blockIDs.contains($0.attributes["id"] ?? "") }
        var amounts: [String] = []
        for block in blocks {
            let conditions = ["prime exclusive", "precio exclusivo", "subscribe & save", "suscríbete", "compra recurrente", "cuotas", "installments", "mensual", "per month", "/mes"]
            if conditions.contains(where: block.text.lowercased().contains) { throw WebPriceError.ambiguous }
            let prices = block.nodes.filter { $0.classes.contains("a-price") && !$0.classes.contains("a-text-price") }
            for price in prices {
                guard !price.text.lowercased().contains("/"),
                      !price.text.lowercased().contains("mes"), !price.text.lowercased().contains("month") else { throw WebPriceError.ambiguous }
                if let amount = price.nodes.first(where: { $0.classes.contains("a-offscreen") })?.text { amounts.append(amount) }
            }
            if (block.attributes["id"] ?? "").hasPrefix("priceblock_") { amounts.append(block.text) }
        }
        guard !amounts.isEmpty else { throw WebPriceError.missing }
        let expectedSymbol: String
        switch item.currency.uppercased() {
        case "EUR": expectedSymbol = "€"
        case "GBP": expectedSymbol = "£"
        case "USD" where item.canonicalURL.host?.hasSuffix("amazon.com") == true: expectedSymbol = "$"
        default: throw WebPriceError.currency
        }
        let results = try amounts.map { raw -> FetchResult in
            guard raw.contains(expectedSymbol) else { throw WebPriceError.currency }
            var amount = raw.replacingOccurrences(of: expectedSymbol, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Only a well-formed regional number, never a quota/unit price.
            let decimal = amount.contains(",") && item.currency == "EUR" ? "," : "."
            let grouping = decimal == "," ? "." : ","
            amount = amount.replacingOccurrences(of: " ", with: "")
            let pattern = "^(?:[0-9]{1,3}(?:" + NSRegularExpression.escapedPattern(for: grouping) + "[0-9]{3})+|[0-9]+)(?:" + NSRegularExpression.escapedPattern(for: decimal) + "[0-9]{2})?$"
            guard amount.range(of: pattern, options: .regularExpression) != nil else { throw WebPriceError.ambiguous }
            amount = amount.replacingOccurrences(of: grouping, with: "").replacingOccurrences(of: decimal, with: ".")
            return try result(amount: amount, currency: item.currency, item: item)
        }
        return try unique(results)
    }

    private static func collect(_ value: Any, products: inout [[String: Any]], graph: inout [String: [String: Any]]) {
        if let array = value as? [Any] { for entry in array { collect(entry, products: &products, graph: &graph) }; return }
        guard let object = value as? [String: Any] else { return }
        if let id = object["@id"] as? String { graph[id] = object }
        let types = (object["@type"] as? [String] ?? [object["@type"] as? String ?? ""]).map { schemaType($0) }
        if types.contains("Product") || (types.contains("ProductGroup") && object["hasVariant"] == nil) { products.append(object) }
        for key in ["@graph", "mainEntity", "hasVariant"] {
            if let nested = object[key] { collect(nested, products: &products, graph: &graph) }
        }
    }
    private static func resolve(_ object: [String: Any], graph: [String: [String: Any]]) -> [String: Any] {
        if object.count == 1, let id = object["@id"] as? String { return graph[id] ?? object }
        return object
    }
    private static func dictionaries(_ value: Any?) -> [[String: Any]] { (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? [] }
    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        if let object = value as? [String: Any] { return object["name"] as? String ?? object["value"] as? String }
        return nil
    }
    private static func normalized(_ value: String) -> String { StorePageParser.decodeHTMLEntities(value).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
    private static func schemaType(_ value: String?) -> String? { value?.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init) }
    private static func absolute(_ value: String?, base: URL) -> URL? { value.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
    private static func hostKey(_ host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private static func sameHost(_ lhs: URL, _ rhs: URL) -> Bool { hostKey(lhs.host) == hostKey(rhs.host) && lhs.port == rhs.port }
    private static func matches(_ url: URL, item: Item) -> Bool {
        guard sameHost(url, item.canonicalURL) else { return false }
        if item.store == .amazon { return AmazonConnector.extractASIN(from: url) == item.storeItemID }
        func key(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
            components.scheme = "https"; components.fragment = nil
            components.host = hostKey(components.host)
            if components.path.hasSuffix("/") { components.path.removeLast() }
            components.queryItems = components.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased()) }.sorted { $0.name < $1.name }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            return components.string ?? ""
        }
        return key(url) == key(item.canonicalURL)
    }
    private static func metadata(_ document: PriceHTML) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for node in document.nodes where node.tag == "meta" {
            if let key = node.attributes["property"]?.lowercased(), let value = node.attributes["content"] { values[key, default: []].append(StorePageParser.decodeHTMLEntities(value)) }
        }
        return values
    }
    private static func nearestProduct(_ node: PriceHTML) -> PriceHTML? {
        var ancestor = node.parent
        while let current = ancestor {
            if schemaType(current.attributes["itemtype"]) == "Product" { return current }
            ancestor = current.parent
        }
        return nil
    }
    private static func properties(_ root: PriceHTML) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for node in root.nodes.dropFirst() {
            var ancestor = node.parent
            var nestedScope = false
            while let current = ancestor, current !== root {
                if current.attributes["itemtype"] != nil { nestedScope = true; break }
                ancestor = current.parent
            }
            if nestedScope { continue }
            guard let key = node.attributes["itemprop"], node.attributes["itemtype"] == nil else { continue }
            values[key, default: []].append(StorePageParser.decodeHTMLEntities(node.attributes["content"] ?? node.attributes["href"] ?? node.text))
        }
        return values
    }
}

/// Small bounded HTML tree for scoped selectors, not a global price regex.
private final class PriceHTML {
    let tag: String
    let attributes: [String: String]
    weak var parent: PriceHTML?
    var children: [PriceHTML] = []
    var rawText = ""
    init(_ tag: String, _ attributes: [String: String] = [:]) { self.tag = tag; self.attributes = attributes }
    var classes: Set<String> { Set((attributes["class"] ?? "").split(separator: " ").map(String.init)) }
    var nodes: [PriceHTML] { [self] + children.flatMap(\.nodes) }
    var text: String {
        if ["script", "style"].contains(tag) { return "" }
        return StorePageParser.decodeHTMLEntities(([rawText] + children.map(\.text)).joined(separator: " ")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func parse(_ html: String) -> PriceHTML {
        let root = PriceHTML("document")
        var stack = [root]
        let regex = try! NSRegularExpression(pattern: #"<script\b[^>]*>.*?</script\s*>|<!--.*?-->|<[^>]+>|[^<]+"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let voidTags: Set<String> = ["meta", "link", "input", "img", "br", "hr", "area", "base", "embed", "source", "wbr"]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(100_000) {
            guard let range = Range(match.range, in: html) else { continue }
            let token = String(html[range])
            if token.hasPrefix("<!--") || token.hasPrefix("<!") { continue }
            if token.hasPrefix("</") {
                let name = token.dropFirst(2).prefix { $0.isLetter || $0.isNumber }.lowercased()
                if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 { stack.removeSubrange(index...) }
            } else if token.hasPrefix("<") {
                let tag = token.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
                guard !tag.isEmpty else { continue }
                let opening = String(token.prefix(through: token.firstIndex(of: ">")!))
                let node = PriceHTML(tag, StorePageParser.attributes(in: opening))
                node.parent = stack.last; stack.last?.children.append(node)
                if tag == "script", let start = token.firstIndex(of: ">"), let end = token.range(of: "</script", options: .caseInsensitive)?.lowerBound {
                    node.rawText = String(token[token.index(after: start)..<end])
                } else if !voidTags.contains(tag) && !token.hasSuffix("/>") && stack.count < 128 { stack.append(node) }
            } else { stack.last?.rawText += token }
        }
        return root
    }
}
