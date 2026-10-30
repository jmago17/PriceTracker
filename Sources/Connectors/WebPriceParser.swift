import Foundation
import CoreFoundation

/// Shared strict extraction for refresh and Amazon add/share. Related products,
/// ranges and unverified variants fail closed; missing evidence is not a price.
enum WebPriceParser {
    static func amazonAddPrice(data: Data, url: URL, title: String, size: String?, color: String?) throws -> FetchResult {
        guard let asin = AmazonConnector.extractASIN(from: url) else { throw WebPriceError.identity }
        let market = AmazonConnector.marketplace(for: url.host)
        let item = Item(store: .amazon, storeItemID: asin, region: market.region, currency: market.currency,
            canonicalURL: url, title: title, size: size, color: color)
        return try parse(data: data, finalURL: url, item: item)
    }

    static func parse(data: Data, finalURL: URL, item: Item, now: Date = Date()) throws -> FetchResult {
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

        let metadata = try metadataPrice(document, base: finalURL, item: item)
        let amazonPrice = item.store == .amazon ? try amazon(document, item: item) : nil
        let pagePrice: FetchResult?
        if let amazonPrice { pagePrice = try reconcile(amazonPrice, with: metadata) }
        else { pagePrice = metadata }
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
                return item.store != .amazon && products.count == 1 && normalized(string(product["name"]) ?? "") == normalized(item.title)
            }
            guard !selected.isEmpty else { throw WebPriceError.identity }
            let results = try selected.map { product -> FetchResult in
                if item.store == .amazon, let sku = string(product["sku"]), sku != item.storeItemID { throw WebPriceError.identity }
                try validateVariant(size: string(product["size"]), color: string(product["color"]), item: item,
                    asinBound: item.store == .amazon && (string(product["sku"]) == item.storeItemID || absolute(string(product["url"]), base: finalURL).map { matches($0, item: item) } == true))
                let offers = dictionaries(product["offers"]).map { resolve($0, graph: graph) }
                guard !offers.isEmpty else { throw WebPriceError.missing }
                let prices = try offers.map { try offer($0, base: finalURL, item: item, now: now) }
                return try unique(prices)
            }
            return try reconcile(unique(results), with: pagePrice)
        }

        let microProducts = document.nodes.filter { !$0.isExcluded && schemaType($0.attributes["itemtype"]) == "Product" }
        if !microProducts.isEmpty {
            let selected = microProducts.filter { node in
                let values = properties(node)
                if let url = absolute(values["url"]?.first, base: finalURL) { return matches(url, item: item) }
                if item.store == .amazon { return values["sku"] == [item.storeItemID] }
                return microProducts.count == 1 && normalized(values["name"]?.first ?? "") == normalized(item.title)
            }
            guard selected.count == 1, let product = selected.first else { throw WebPriceError.identity }
            let values = properties(product)
            if item.store == .amazon, let skus = values["sku"], skus.contains(where: { $0 != item.storeItemID }) { throw WebPriceError.identity }
            try validateVariant(size: values["size"]?.first, color: values["color"]?.first, item: item, asinBound: item.store == .amazon)
            let offers = product.nodes.filter { schemaType($0.attributes["itemtype"]) == "Offer" && nearestProduct($0) === product }
            guard !offers.isEmpty else { throw WebPriceError.missing }
            let result = try unique(offers.map { node in
                let props = properties(node)
                guard props["price"]?.count == 1, props["priceCurrency"]?.count == 1,
                      ["validFrom", "validThrough", "priceValidUntil"].allSatisfy({ Set(props[$0] ?? []).count <= 1 }),
                      !node.nodes.contains(where: {
                          schemaType($0.attributes["itemtype"]) == "UnitPriceSpecification"
                              || ["eligibleQuantity", "eligibleTransactionVolume", "eligibleCustomerType", "validForMemberTier", "priceSpecification"].contains($0.attributes["itemprop"] ?? "")
                      }) else { throw WebPriceError.ambiguous }
                var dictionary: [String: Any] = [:]
                for (key, value) in props { if let first = value.first { dictionary[key] = first } }
                return try offer(dictionary, base: finalURL, item: item, now: now)
            })
            return try reconcile(result, with: pagePrice)
        }

        if item.store == .amazon {
            guard let pagePrice else { throw WebPriceError.missing }
            return pagePrice
        }
        guard let pagePrice else { throw WebPriceError.missing }
        try validateVariant(size: nil, color: nil, item: item, asinBound: false)
        return pagePrice
    }

    /// Compare every present price/currency namespace, never prefer one by order.
    /// These page-level values must be explicitly bound to the saved product.
    private static func metadataPrice(_ document: PriceHTML, base: URL, item: Item) throws -> FetchResult? {
        let meta = metadata(document)
        let states = (meta["product:availability"] ?? []) + (meta["og:availability"] ?? [])
        for state in states {
            let value = (schemaType(state) ?? state).lowercased().filter { $0.isLetter }
            guard ["instock", "available", "limitedavailability", "preorder", "backorder", "onlineonly"].contains(value) else { throw WebPriceError.missing }
        }
        guard let types = meta["og:type"], !types.isEmpty, types.allSatisfy({ $0.lowercased() == "product" }),
              let urls = meta["og:url"], !urls.isEmpty else { return nil }
        guard urls.allSatisfy({ absolute($0, base: base).map { matches($0, item: item) } == true }) else { throw WebPriceError.identity }
        let amounts = (meta["product:price:amount"] ?? []) + (meta["og:price:amount"] ?? [])
        let currencies = (meta["product:price:currency"] ?? []) + (meta["og:price:currency"] ?? [])
        if amounts.isEmpty && currencies.isEmpty { return nil }
        guard !amounts.isEmpty, !currencies.isEmpty else { throw WebPriceError.ambiguous }
        // Checking each currency also rejects a conflicting namespace even when
        // it omits its own amount. Numeric equivalents such as 10 and 10.00 agree.
        for currency in currencies { _ = try result(amount: amounts[0], currency: currency, item: item) }
        return try unique(amounts.map { try result(amount: $0, currency: currencies[0], item: item) })
    }

    private static func reconcile(_ value: FetchResult, with pagePrice: FetchResult?) throws -> FetchResult {
        if let pagePrice { _ = try unique([value, pagePrice]) }
        return value
    }

    private static func offer(_ offer: [String: Any], base: URL, item: Item, now: Date) throws -> FetchResult {
        let types = (offer["@type"] as? [String] ?? [string(offer["@type"]) ?? "Offer"]).compactMap(schemaType)
        guard types.contains("Offer"), !types.contains("AggregateOffer"), offer["lowPrice"] == nil, offer["highPrice"] == nil else { throw WebPriceError.ambiguous }
        guard offer["priceSpecification"] == nil,
              ["billingDuration", "billingIncrement", "referenceQuantity", "unitCode", "eligibleQuantity", "eligibleTransactionVolume", "eligibleCustomerType", "validForMemberTier"].allSatisfy({ offer[$0] == nil }) else { throw WebPriceError.conditions }
        if let region = offer["eligibleRegion"] {
            let regions = (region as? [String]) ?? string(region).map { [$0] } ?? []
            guard regions.map({ $0.uppercased() }).contains(item.region.uppercased()) else { throw WebPriceError.ambiguous }
        }
        if let function = string(offer["businessFunction"]), schemaType(function) != "Sell" { throw WebPriceError.ambiguous }
        if let condition = string(offer["itemCondition"]), schemaType(condition) != "NewCondition" { throw WebPriceError.ambiguous }
        if let availability = string(offer["availability"]), !["InStock", "LimitedAvailability", "PreOrder", "BackOrder", "OnlineOnly"].contains(schemaType(availability) ?? "") { throw WebPriceError.missing }
        try validateValidity(offer, now: now)
        if let url = absolute(string(offer["url"]), base: base), !matches(url, item: item) { throw WebPriceError.variant }
        guard let amount = string(offer["price"]), let currency = string(offer["priceCurrency"]) else { throw WebPriceError.missing }
        var value = try result(amount: amount, currency: currency, item: item)
        value.availability = string(offer["availability"]).flatMap(schemaType) ?? "unknown"
        return value
    }

    private static func validateValidity(_ offer: [String: Any], now: Date) throws {
        for field in ["validFrom", "validThrough", "priceValidUntil"] {
            guard let raw = offer[field] else { continue }
            guard let text = raw as? String else { throw WebPriceError.ambiguous }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isStart = field == "validFrom"
            let dateOnly = value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            let day = String(value.prefix(10))
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = Calendar(identifier: .gregorian)
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.isLenient = false
            guard let parsedDay = dayFormatter.date(from: day), dayFormatter.string(from: parsedDay) == day else { throw WebPriceError.ambiguous }
            let date: Date
            if dateOnly {
                // Date-only bounds use UTC calendar days; an end date includes
                // that entire day, without rounding away fractional seconds.
                date = isStart ? parsedDay : parsedDay.addingTimeInterval(86_400)
            } else {
                guard value.range(of: #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:(?:0\d|1[0-3]):[0-5]\d|14:00))$"#, options: .regularExpression) != nil else { throw WebPriceError.ambiguous }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
                guard let parsed = formatter.date(from: value) else { throw WebPriceError.ambiguous }
                date = parsed
            }
            if isStart {
                guard now >= date else { throw WebPriceError.missing }
            } else {
                guard dateOnly ? now < date : now <= date else { throw WebPriceError.missing }
            }
        }
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
        guard values.allSatisfy({ $0.priceCents == first.priceCents && $0.currency == first.currency }) else { throw WebPriceError.conflict }
        return first
    }

    private static func validateVariant(size: String?, color: String?, item: Item, asinBound: Bool) throws {
        for (expected, actual) in [(item.size, size), (item.color, color)] {
            guard let expected = expected?.trimmedNonEmpty else { continue }
            if let actual { guard normalized(expected) == normalized(actual) else { throw WebPriceError.variant } }
            else if !asinBound { throw WebPriceError.variant }
        }
    }

    private static let unavailableMarkers = ["currently unavailable", "temporarily out", "no disponible", "agotado", "indisponible",
        "derzeit nicht verfügbar", "attualmente non disponibile", "non disponibile"]
    private static let noOfferMarkers = [
        "ofertas destacadas no disponibles", "no hay ofertas destacadas", "no featured offers available", "no featured offer",
        "derzeit keine hervorgehobenen angebote", "keine hervorgehobenen angebote", "offre vedette non disponible", "aucune offre vedette",
        "nessuna offerta in evidenza", "offerte in evidenza non disponibili"]

    private static func amazon(_ document: PriceHTML, item: Item) throws -> FetchResult? {
        let selectedASINs = Set(document.nodes.filter {
            $0.tag == "input" && ($0.attributes["id"] == "ASIN" || $0.attributes["name"] == "ASIN")
        }.compactMap { $0.attributes["value"] }.filter { !$0.isEmpty })
        if !selectedASINs.isEmpty && selectedASINs != [item.storeItemID] { throw WebPriceError.identity }
        // Amazon's selected ASIN identifies the chosen child variant. Any explicit
        // selected values we can see must still match the user's stored variant.
        for (id, expected) in [("variation_size_name", item.size), ("variation_color_name", item.color)] {
            if let expected, let section = document.nodes.first(where: { $0.attributes["id"] == id }),
               let selection = section.nodes.first(where: { $0.classes.contains("selection") }),
               normalized(selection.text) != normalized(expected) { throw WebPriceError.variant }
        }
        if let availability = document.nodes.first(where: { $0.attributes["id"] == "availability" })?.text.lowercased(),
           unavailableMarkers.contains(where: availability.contains) {
            throw WebPriceError.noOffer
        }
        let blockIDs = ["corePriceDisplay_desktop_feature_div", "corePrice_feature_div", "apex_desktop", "apex_mobile", "priceblock_ourprice", "priceblock_dealprice"]
        let blocks = document.nodes.filter { !$0.isExcluded && blockIDs.contains($0.attributes["id"] ?? "") }
        guard !blocks.isEmpty else {
            // Without a product price block, a stated absence of featured offer is a
            // store state, not an extraction failure. Other prices are never used.
            let visible = normalized(document.text)
            if noOfferMarkers.contains(where: visible.contains) { throw WebPriceError.noOffer }
            return nil
        }
        guard selectedASINs == [item.storeItemID],
              document.nodes.contains(where: { !$0.isExcluded && $0.attributes["id"] == "productTitle" && !$0.text.isEmpty }) else { throw WebPriceError.identity }
        var amounts: [String] = []
        for block in blocks {
            var ancestor: PriceHTML? = block
            while let node = ancestor {
                if let asin = node.attributes["data-asin"], !asin.isEmpty, asin != item.storeItemID { throw WebPriceError.identity }
                let context = ((node.attributes["id"] ?? "") + " " + (node.attributes["class"] ?? "")).lowercased()
                if context.range(of: #"recommend|accessor|sponsored|frequently[-_ ]?bought|sims-|similar|bundle"#, options: .regularExpression) != nil { throw WebPriceError.ambiguous }
                ancestor = node.parent
            }
            if hasConditionalPrice(in: block) { throw WebPriceError.conditions }
            let prices = block.nodes.filter { !$0.isExcluded && $0.classes.contains("a-price") && !$0.classes.contains("a-text-price") }
            for node in block.nodes where !node.isExcluded {
                if let asin = node.attributes["data-asin"], !asin.isEmpty, asin != item.storeItemID { throw WebPriceError.identity }
            }
            for price in prices {
                guard !price.text.lowercased().contains("/"),
                      !price.text.lowercased().contains("mes"), !price.text.lowercased().contains("month") else { throw WebPriceError.ambiguous }
                let labels = price.nodes.filter { !$0.isExcluded && $0.classes.contains("a-offscreen") }
                if labels.isEmpty { throw WebPriceError.ambiguous }
                amounts.append(contentsOf: labels.map(\.text))
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

    /// Additional rejection signals inside the price area, not proof that any
    /// unrecognized wording is unconditional. Unknown page layouts can still fail.
    private static func hasConditionalPrice(in block: PriceHTML) -> Bool {
        let annotations = block.nodes.filter { !$0.isExcluded }.flatMap { node in
            ["aria-label", "title", "alt", "class", "id"].compactMap { node.attributes[$0] }
        }
        let text = normalized(([block.text] + annotations).joined(separator: " "))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es_ES"))
        let patterns = [
            #"\b(?:\d+|tres|three)\s*(?:pagos?|cuotas?|payments?|instalments?|installments?)\b"#,
            #"\b(?:al|por|per|a)\s+(?:mes|month|semana|week|ano|year)\b"#,
            #"(?:/|\bper\s+)(?:mes|mo|month|week|ano|year)\b"#,
            #"\b(?:prime|miembros?|members?|socios?|cuotas?|mensual|monthly|installments?|instalments?|financing|financiacion|subscription|membership)\b"#,
            #"subscribe|suscrib|precio exclusivo|compra recurrente|prime[-_ ]?(?:exclusive|member|price)"#,
            #"\b(?:envio|shipping|delivery|accesorios?|accessor(?:y|ies)|recomendados?|recommended|por unidad|per unit)\b"#,
            #"\b\d+\s*[x×]\s*(?:[€£$]|\d)|\bpaga(?:r)?\s+en\s+\d+\b"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
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
        for node in root.nodes.dropFirst() where !node.isExcluded {
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
    var isExcluded: Bool {
        if ["script", "style", "template", "noscript"].contains(tag) { return true }
        if attributes["hidden"] != nil || attributes["aria-hidden"] == "true" { return true }
        let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        if style.contains("display:none") || style.contains("visibility:hidden") ||
            !classes.isDisjoint(with: ["aok-hidden", "a-hidden", "hidden"]) { return true }
        return parent?.isExcluded ?? false
    }
    var text: String {
        if isExcluded { return "" }
        return StorePageParser.decodeHTMLEntities(([rawText] + children.map(\.text)).joined(separator: " ")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func htmlAttributes(_ opening: String) -> [String: String] {
        var values: [String: String] = [:]
        // Consume a whole quoted/unquoted attribute, never reinterpret text
        // inside an aria-label/title as a new attribute (including hidden).
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: opening, range: NSRange(opening.startIndex..., in: opening)) {
            guard let keyRange = Range(match.range(at: 1), in: opening) else { continue }
            let key = String(opening[keyRange]).lowercased()
            let value = (2...4).compactMap { Range(match.range(at: $0), in: opening) }.first
            if let value { values[key] = StorePageParser.decodeHTMLEntities(String(opening[value])) }
            else if key == "hidden" { values[key] = "" }
        }
        return values
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
                let node = PriceHTML(tag, htmlAttributes(opening))
                node.parent = stack.last; stack.last?.children.append(node)
                if tag == "script", let start = token.firstIndex(of: ">"), let end = token.range(of: "</script", options: .caseInsensitive)?.lowerBound {
                    node.rawText = String(token[token.index(after: start)..<end])
                } else if !voidTags.contains(tag) && !token.hasSuffix("/>") && stack.count < 128 { stack.append(node) }
            } else {
                // Keep text in DOM order, including labels split across spans.
                let text = PriceHTML("#text")
                text.rawText = token
                text.parent = stack.last
                stack.last?.children.append(text)
            }
        }
        return root
    }
}
