import Foundation
import Testing
@testable import PriceTracker

struct WebPriceParserTests {
    private func item(_ url: String = "https://shop.example/product", store: Store = .generic, currency: String = "EUR") -> Item {
        Item(store: store, storeItemID: store == .amazon ? "B012345678" : url, currency: currency,
             canonicalURL: URL(string: url)!, title: "Cámara Demo", priceCurrentCents: 1999,
             priceAtAddCents: 1999, lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func parse(_ html: String, item: Item? = nil, finalURL: URL? = nil, now: Date? = nil) throws -> FetchResult {
        let item = item ?? self.item()
        return try WebPriceParser.parse(data: Data(html.utf8), finalURL: finalURL ?? item.canonicalURL, item: item, now: now ?? ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!)
    }
    private func json(_ body: String) -> String { "<script type='application/ld+json'>\(body)</script>" }
    private func product(_ offers: String, extra: String = "") -> String {
        json("""
        {"@type":"Product","name":"Cámara Demo","url":"https://shop.example/product",\(extra)"offers":\(offers)}
        """)
    }

    @Test func exactPriceUsesDecimalCurrencyAndIgnoresRelatedProduct() throws {
        let html = json("""
        [{"@type":"Product","name":"Relacionado","url":"https://shop.example/other","offers":{"price":"1.99","priceCurrency":"EUR"}},
         {"@type":"Product","name":"Cámara Demo","url":"https://shop.example/product","offers":{"@type":"Offer","price":"1299.95","priceCurrency":"EUR"}}]
        """)
        #expect(try parse(html).priceCents == 129995)
        #expect(WebPriceParser.cents("0") == 0)
        for invalid in ["NaN", "Infinity", "-1", "1e3", "1,99", "1.999", "20/month", "1–2", "true"] {
            #expect(WebPriceParser.cents(invalid) == nil)
        }
    }

    @Test func rangesMultipleOffersCurrencyAndInstallmentsFailClosed() {
        let offers = [
            #"{"@type":"AggregateOffer","lowPrice":"10","highPrice":"20","priceCurrency":"EUR"}"#,
            #"[{"price":"10","priceCurrency":"EUR"},{"price":"20","priceCurrency":"EUR"}]"#,
            #"{"price":"10","priceCurrency":"USD"}"#,
            #"{"price":"10","priceCurrency":"EUR","priceSpecification":{"@type":"UnitPriceSpecification","billingDuration":"P1M"}}"#,
            #"{"price":"10","priceCurrency":"EUR","validForMemberTier":"Prime"}"#,
            #"{"price":"10","priceCurrency":"EUR","availability":"https://schema.org/OutOfStock"}"#,
            #"{"price":true,"priceCurrency":"EUR"}"#,
            #"{"price":"10","priceCurrency":"EUR","eligibleRegion":"US"}"#
        ]
        for value in offers { #expect(throws: (any Error).self) { try parse(product(value)) } }
    }

    @Test func matchingVariantAndGraphOfferReferences() throws {
        var selected = item(); selected.color = "Azul"; selected.size = "M"
        let html = json("""
        {"@graph":[{"@type":"ProductGroup","hasVariant":[
        {"@type":"Product","url":"https://shop.example/other","name":"Otra","color":"Rojo","size":"L","offers":{"price":"2","priceCurrency":"EUR"}},
        {"@type":"Product","url":"https://shop.example/product","name":"Cámara Demo","color":"Azul","size":"M","offers":{"@id":"#offer"}}]},
        {"@id":"#offer","@type":"Offer","price":"19.99","priceCurrency":"EUR"}]}
        """)
        #expect(try parse(html, item: selected).priceCents == 1999)
        selected.size = "L"
        #expect(throws: (any Error).self) { try parse(html, item: selected) }
        #expect(throws: (any Error).self) { try parse(product(#"{"price":"10","priceCurrency":"EUR"}"#), item: selected) }
    }

    @Test func metadataRequiresProductBindingAndNoUnknownVariant() throws {
        let html = """
        <meta property="og:type" content="product"><meta property="og:url" content="https://shop.example/product">
        <meta property="product:price:amount" content="24.95"><meta property="product:price:currency" content="EUR">
        """
        #expect(try parse(html).priceCents == 2495)
        #expect(throws: (any Error).self) { try parse(html.replacingOccurrences(of: "example/product", with: "example/other")) }
        #expect(throws: (any Error).self) { try parse(html + "<meta property='product:price:amount' content='1.00'>") }
        var selected = item(); selected.color = "Verde"
        #expect(throws: (any Error).self) { try parse(html, item: selected) }
    }

    @Test func microdataUsesOnlyTheSelectedProductOffer() throws {
        let html = """
        <div itemscope itemtype="https://schema.org/Product"><a itemprop="url" href="https://shop.example/product"></a>
        <span itemprop="name">Cámara Demo</span><div itemprop="offers" itemscope itemtype="https://schema.org/Offer">
        <meta itemprop="price" content="29.90"><meta itemprop="priceCurrency" content="EUR"></div></div>
        <div itemscope itemtype="https://schema.org/Product"><a itemprop="url" href="/other"></a>
        <div itemscope itemtype="https://schema.org/Offer"><meta itemprop="price" content="1.00"><meta itemprop="priceCurrency" content="EUR"></div></div>
        """
        #expect(try parse(html).priceCents == 2990)
    }

    @Test func blockedDynamicAndRedirectedPagesDoNotReturnAPrice() {
        let valid = product(#"{"price":"10","priceCurrency":"EUR"}"#)
        for html in ["<title>Robot Check</title>" + valid, "<form action='/errors/validateCaptcha'></form>" + valid, "<title>Dynamic shop</title><div id='app'></div>"] {
            #expect(throws: (any Error).self) { try parse(html) }
        }
        #expect(throws: (any Error).self) { try parse(valid, finalURL: URL(string: "https://shop.example/other")!) }
        #expect(throws: (any Error).self) { try parse(valid, finalURL: URL(string: "https://different.example/product")!) }
    }

    @Test func canonicalRedirectAndTrackingAreAcceptedWithoutDroppingVariantParameters() throws {
        let html = product(#"{"price":"10","priceCurrency":"EUR"}"#) + "<link rel='canonical' href='https://shop.example/product'>"
        #expect(try parse(html, finalURL: URL(string: "https://shop.example/new-slug")!).priceCents == 1000)
        #expect(try parse(html, item: item("https://shop.example/product?utm_source=mail")).priceCents == 1000)
        #expect(throws: (any Error).self) { try parse(html, item: item("https://shop.example/product?variant=blue")) }
    }

    @Test func amazonBuyBoxExcludesListRelatedAndUnitPrices() throws {
        let selected = item("https://www.amazon.es/dp/B012345678", store: .amazon)
        let html = """
        <input id="ASIN" value="B012345678"><span id="productTitle">Cámara Demo</span>
        <div id="corePriceDisplay_desktop_feature_div">
        <span class="a-price a-text-price"><span class="a-offscreen">1.599,00 €</span></span>
        <span class="a-price"><span class="a-offscreen">1.299,95 €</span></span></div>
        <div id="recommendations"><span class="a-price"><span class="a-offscreen">2,00 €</span></span></div>
        """
        #expect(try parse(html, item: selected).priceCents == 129995)
        #expect(throws: (any Error).self) { try parse(html + "<input name='ASIN' value='B099999999'>", item: selected) }
        #expect(throws: (any Error).self) { try parse(html.replacingOccurrences(of: "B012345678", with: "B099999999"), item: selected) }
        #expect(throws: (any Error).self) { try parse(html.replacingOccurrences(of: "1.299,95 €", with: "19,99 €/mes"), item: selected) }
        #expect(throws: (any Error).self) { try parse(html.replacingOccurrences(of: "1.299,95 €", with: "$1299.95"), item: selected) }
    }
    @Test func amazonRegionalFormatsAndConditionalPrices() throws {
        for (host, currency, amount) in [("amazon.es", "EUR", "1 299,95 €"), ("amazon.co.uk", "GBP", "£1,299.95"), ("amazon.com", "USD", "$1,299.95")] {
            let selected = item("https://www.\(host)/dp/B012345678", store: .amazon, currency: currency)
            let html = "<input id='ASIN' value='B012345678'><span id='productTitle'>Cámara Demo</span><div id='corePrice_feature_div'><span class='a-price'><span class='a-offscreen'>\(amount)</span></span></div>"
            #expect(try parse(html, item: selected).priceCents == 129995)
            #expect(throws: (any Error).self) { try parse(html.replacingOccurrences(of: "</div>", with: "Prime exclusive deal</div>"), item: selected) }
        }
    }

    @Test func aggregateGroupCannotFallBackToAnUnqualifiedMinimum() {
        let group = json(#"{"@type":"ProductGroup","name":"Cámara Demo","url":"https://shop.example/product","offers":{"@type":"AggregateOffer","lowPrice":"10","highPrice":"100","priceCurrency":"EUR"}}"#)
        #expect(throws: (any Error).self) { try parse(group) }
    }

    @Test func loginAndUnavailableAmazonPreserveTheUnverifiedState() {
        let selected = item("https://www.amazon.es/dp/B012345678", store: .amazon)
        let html = "<input id='ASIN' value='B012345678'><span id='productTitle'>Cámara Demo</span><div id='availability'>Actualmente no disponible</div><span id='priceblock_ourprice'>19,99 €</span>"
        #expect(throws: (any Error).self) { try parse(html, item: selected) }
        #expect(throws: (any Error).self) { try parse(html, item: selected, finalURL: URL(string: "https://www.amazon.es/ap/signin")!) }
    }

    @Test func microdataQuantityConditionAndMeaningfulQueryDoNotBecomeRegularPrice() {
        let html = "<div itemscope itemtype='https://schema.org/Product'><meta itemprop='name' content='Cámara Demo'><div itemscope itemtype='https://schema.org/Offer'><meta itemprop='price' content='1.00'><meta itemprop='priceCurrency' content='EUR'><div itemprop='eligibleQuantity' itemscope itemtype='https://schema.org/QuantitativeValue'><meta itemprop='minValue' content='100'></div></div></div>"
        #expect(throws: (any Error).self) { try parse(html) }
        let regular = product(#"{"price":"10","priceCurrency":"EUR"}"#)
        #expect(throws: (any Error).self) { try parse(regular, item: item("https://shop.example/product?ref=blue")) }
    }

    @Test func conflictingMetadataAndOutOfStockCannotReturnAPrice() {
        let base = "<meta property='og:type' content='product'><meta property='og:url' content='https://shop.example/product'><meta property='product:price:amount' content='10'><meta property='product:price:currency' content='EUR'>"
        for extra in ["<meta property='og:price:amount' content='100'><meta property='og:price:currency' content='EUR'>", "<meta property='og:price:amount' content='10'><meta property='og:price:currency' content='USD'>", "<meta property='product:availability' content='out of stock'>"] {
            #expect(throws: (any Error).self) { try parse(base + extra) }
        }
    }

    @Test func futureExpiredAndMalformedOfferValidityFails() {
        for interval in [#","validFrom":"2099-01-01""#, #","validThrough":"2000-01-01""#, #","validFrom":"not a date""#] {
            let offer = #"{"price":"10","priceCurrency":"EUR""# + interval + "}"
            #expect(throws: (any Error).self) { try parse(product(offer)) }
        }
    }

    @Test func amazonInstallmentsAndMembershipAreNotTheTotalPrice() {
        let selected = item("https://www.amazon.es/dp/B012345678", store: .amazon)
        for condition in ["3 pagos de", "al mes", "con Prime", "for Prime members"] {
            let html = "<input id='ASIN' value='B012345678'><span id='productTitle'>Cámara Demo</span><div id='corePrice_feature_div'>\(condition)<span class='a-price'><span class='a-offscreen'>19,99 €</span></span></div>"
            #expect(throws: (any Error).self) { try parse(html, item: selected) }
        }
    }

    @Test func matchingMetadataAgreesNumericallyButCannotContradictStructuredOffer() throws {
        let meta = "<meta property='og:type' content='product'><meta property='og:url' content='https://shop.example/product'><meta property='product:price:amount' content='10'><meta property='product:price:currency' content='eur'><meta property='og:price:amount' content='10.00'><meta property='og:price:currency' content='EUR'><meta property='product:availability' content='in stock'>"
        #expect(try parse(meta).priceCents == 1000)
        #expect(throws: (any Error).self) { try parse(meta + product(#"{"price":"100","priceCurrency":"EUR"}"#)) }
    }

    @Test func offerValidityUsesInjectedClockForBoundariesAndRejectsEveryMalformedField() throws {
        let clock = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
        func page(_ fields: [String: Any]) throws -> String {
            var offer: [String: Any] = ["price": "10", "priceCurrency": "EUR"]
            offer.merge(fields) { _, new in new }
            return product(String(decoding: try JSONSerialization.data(withJSONObject: offer), as: UTF8.self))
        }
        let valid = try page(["validFrom": "2026-10-12T14:00:00+02:00", "validThrough": "2026-10-12T12:00:00.500Z", "priceValidUntil": "2026-10-12"])
        #expect(try parse(valid, now: clock).priceCents == 1000)
        #expect(throws: (any Error).self) { try parse(valid, now: clock.addingTimeInterval(-0.001)) }
        #expect(throws: (any Error).self) { try parse(valid, now: clock.addingTimeInterval(0.501)) }
        #expect(try parse(page(["validFrom": "2026-10-12", "validThrough": "2026-10-12"]), now: clock).priceCents == 1000)
        #expect(throws: (any Error).self) { try parse(page(["priceValidUntil": "2026-10-11", "validThrough": "2099-01-01"]), now: clock) }
        for field in ["validFrom", "validThrough", "priceValidUntil"] {
            let malformed: [Any] = ["", "not a date", "2026-02-30", "2026-02-30T12:00:00Z", "2026-10-12T12:00:00", "2026-10-12T99:00:00Z", NSNull(), 42, ["2026-10-12"]]
            for value in malformed {
                #expect(throws: (any Error).self) { try parse(page([field: value]), now: clock) }
            }
        }
    }

    @Test func amazonConditionLabelsRetainDOMOrderAndAccessibleAnnotations() {
        let selected = item("https://www.amazon.es/dp/B012345678", store: .amazon)
        for condition in ["3 <span>pagos</span> de", "al&nbsp;<span>mes</span>", "<img alt='for Prime members'>", "<span aria-label='con Prime'></span>", "3 x "] {
            let html = "<input id='ASIN' value='B012345678'><span id='productTitle'>Cámara Demo</span><div id='corePrice_feature_div'>\(condition)<span class='a-price'><span class='a-offscreen'>19,99 €</span></span></div>"
            #expect(throws: (any Error).self) { try parse(html, item: selected) }
        }
    }

}

// Explicit synthetic fixtures, not the historical Amazon incident DOM.
struct AmazonPriceReconciliationTests {
    private let url = URL(string: "https://www.amazon.es/dp/B07VLJ5JDV")!
    private var selected: Item {
        Item(store: .amazon, storeItemID: "B07VLJ5JDV", currency: "EUR", canonicalURL: url,
             title: "Cámara sintética", size: "Kit", color: "Negro")
    }
    private func structured(_ price: String = "1090.99", asin: String = "B07VLJ5JDV", fields: String = "") -> String {
        """
        <script type='application/ld+json'>{"@type":"Product","sku":"\(asin)","url":"https://www.amazon.es/dp/\(asin)","name":"Cámara sintética",\(fields)"offers":{"@type":"Offer","price":"\(price)","priceCurrency":"EUR"}}</script>
        """
    }
    private func box(_ price: String = "1.090,99 €", extra: String = "") -> String {
        """
        <input id='ASIN' value='B07VLJ5JDV'><span id='productTitle'>Cámara sintética</span>
        <div id='variation_color_name'><span class='selection'>Negro</span></div>
        <div id='corePrice_feature_div'>\(extra)<span class='a-price'><span class='a-offscreen'>\(price)</span><span aria-hidden='true'>1.090<small>99</small>€</span></span></div>
        """
    }
    private func parse(_ html: String) throws -> FetchResult {
        try WebPriceParser.parse(data: Data(html.utf8), finalURL: url, item: selected)
    }

    @Test func structuredAndVisibleMustAgreeButEitherCanStandAlone() throws {
        #expect(try parse(structured() + box()).priceCents == 109099)
        #expect(try parse(structured()).priceCents == 109099)
        #expect(try parse(box()).priceCents == 109099)
        #expect(throws: (any Error).self) { try parse(structured("12.39") + box()) }
        #expect(throws: (any Error).self) { try parse(structured() + box("12,39 €")) }
        // A small total can be legitimate: never use a price floor.
        #expect(try parse(structured("12.39") + box("12,39 €")).priceCents == 1239)
    }

    @Test func structuredCannotHideDOMConditionsCurrencyOrVariantConflict() {
        for condition in ["12,39 € al mes", "3 <span>pagos</span> de", "Envío 12,39 €", "precio por unidad", "subscription", "<span aria-label='financing'></span>"] {
            #expect(throws: (any Error).self) { try parse(structured() + box(extra: condition)) }
        }
        for price in ["12,39 € al mes", "12,39 €–1.090,99 €", "$1090.99", "EUR 1090.99 USD", "1.090,99 € + envío"] {
            #expect(throws: (any Error).self) { try parse(structured() + box(price)) }
        }
        #expect(throws: (any Error).self) { try parse(structured() + box().replacingOccurrences(of: "Negro", with: "Rojo")) }
        #expect(throws: (any Error).self) { try parse(structured() + box().replacingOccurrences(of: "value='B07VLJ5JDV'", with: "value='B000000001'")) }
        #expect(throws: (any Error).self) { try parse(structured(fields: "\"color\":\"Rojo\",")) }
    }

    @Test func accessoryBeforeMainHiddenNodesAndAccessibleDuplicates() throws {
        let accessory = structured("12.39", asin: "B000000001")
        let hidden = "<span hidden class='a-price'><span class='a-offscreen'>12,39 €</span></span><span style='display: none' class='a-price'><span class='a-offscreen'>13,39 €</span></span>"
        #expect(try parse(accessory + structured() + box(extra: hidden)).priceCents == 109099)
        let duplicate = "<span class='a-price'><span class='a-offscreen'>1.090,99 €</span></span>"
        #expect(try parse(box(extra: duplicate)).priceCents == 109099)
        #expect(throws: (any Error).self) { try parse(box(extra: duplicate.replacingOccurrences(of: "1.090,99", with: "12,39"))) }
        #expect(throws: (any Error).self) { try parse(box(extra: "<div data-asin='B000000001'>Otro producto</div>")) }
        for scope in ["data-asin='B000000001'", "id='recommendations'", "class='sponsored-accessories'"] {
            let scoped = box().replacingOccurrences(of: "<div id='corePrice_feature_div'>", with: "<div \(scope)><div id='corePrice_feature_div'>") + "</div>"
            #expect(throws: (any Error).self) { try parse(structured() + scoped) }
        }
        #expect(throws: (any Error).self) { try parse(accessory) }
    }

    @Test func metadataUsesSameContractAndDoesNotBindAccessory() throws {
        let page = "<title>Cámara sintética</title>" + structured("12.39", asin: "B000000001") + structured() + box()
        let metadata = try #require(StorePageParser.parse(data: Data(page.utf8), fallbackURL: url))
        #expect(metadata.priceCents == 109099 && metadata.currency == "EUR")
        let conflict = page.replacingOccurrences(of: "\"price\":\"1090.99\"", with: "\"price\":\"12.39\"")
        #expect(StorePageParser.parse(data: Data(conflict.utf8), fallbackURL: url)?.priceCents == nil)
    }
}
