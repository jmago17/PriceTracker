import Foundation
import Testing
@testable import PriceTracker

struct WebPriceParserTests {
    private func item(_ url: String = "https://shop.example/product", store: Store = .generic, currency: String = "EUR") -> Item {
        Item(store: store, storeItemID: store == .amazon ? "B012345678" : url, currency: currency,
             canonicalURL: URL(string: url)!, title: "Cámara Demo", priceCurrentCents: 1999,
             priceAtAddCents: 1999, lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func parse(_ html: String, item: Item? = nil, finalURL: URL? = nil) throws -> FetchResult {
        let item = item ?? self.item()
        return try WebPriceParser.parse(data: Data(html.utf8), finalURL: finalURL ?? item.canonicalURL, item: item)
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

}
