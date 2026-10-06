import Foundation
import Testing
@testable import PriceTracker

/// The iTunes Search API answers HTTP 400 to ISO alpha-3 country codes, which is
/// exactly what `Storefront.countryCode` returns. These tests pin the mapping so
/// the regression cannot come back silently.
struct ISOCountryCodesTests {
    @Test func mapsStorefrontAlphaThreeCodesToAlphaTwo() {
        #expect(ISOCountryCodes.alpha2(from: "ESP") == "ES")
        #expect(ISOCountryCodes.alpha2(from: "USA") == "US")
        #expect(ISOCountryCodes.alpha2(from: "GBR") == "GB")
        #expect(ISOCountryCodes.alpha2(from: "JPN") == "JP")
        #expect(ISOCountryCodes.alpha2(from: "DEU") == "DE")
    }

    @Test func passesAlphaTwoCodesThroughUnchanged() {
        #expect(ISOCountryCodes.alpha2(from: "ES") == "ES")
        #expect(ISOCountryCodes.alpha2(from: "us") == "US")
    }

    @Test func rejectsValuesThatCannotBeMapped() {
        #expect(ISOCountryCodes.alpha2(from: "") == nil)
        #expect(ISOCountryCodes.alpha2(from: "ZZZ") == nil)
        #expect(ISOCountryCodes.alpha2(from: "SPAIN") == nil)
    }

    @Test func tableCoversEveryCountryAndOnlyUsesWellFormedCodes() {
        #expect(ISOCountryCodes.alpha3ToAlpha2.count > 240)
        for (alpha3, alpha2) in ISOCountryCodes.alpha3ToAlpha2 {
            #expect(alpha3.count == 3)
            #expect(alpha2.count == 2)
            #expect(alpha3 == alpha3.uppercased())
            #expect(alpha2 == alpha2.uppercased())
        }
    }
}

struct AppleStorefrontRegionProviderTests {
    @Test func normalizesStorefrontCodeToAlphaTwo() async {
        let provider = AppleStorefrontRegionProvider(resolver: { "ESP" })
        #expect(await provider.region(fallback: "ES") == "ES")
    }

    @Test func normalizesFallbackWhenStorefrontIsUnavailable() async {
        let provider = AppleStorefrontRegionProvider(resolver: { nil })
        #expect(await provider.region(fallback: "ESP") == "ES")
    }

    @Test func ignoresUnmappableStorefrontAndUsesFallback() async {
        let provider = AppleStorefrontRegionProvider(resolver: { "ZZZ" })
        #expect(await provider.region(fallback: "ES") == "ES")
    }

    @Test func fallsBackToUnitedStatesWhenNothingIsUsable() async {
        let provider = AppleStorefrontRegionProvider(resolver: { "" })
        #expect(await provider.region(fallback: "nonsense") == "US")
    }
}
