import Foundation
import StoreKit

/// Resolves the App Store storefront attached to the signed-in Apple account.
///
/// `Storefront.countryCode` is ISO 3166-1 **alpha-3** ("ESP", "USA"), while the
/// iTunes Search API only accepts **alpha-2** ("ES", "US") and returns HTTP 400
/// for anything else — confirmed against the live endpoint. Passing the raw
/// storefront code straight through therefore breaks every Apple price lookup,
/// so values are normalized here and anything unmappable falls back instead of
/// issuing a request that cannot succeed. Tests and previews inject a fixed value.
struct AppleStorefrontRegionProvider: Sendable {
    private let resolver: @Sendable () async -> String?

    init(resolver: @escaping @Sendable () async -> String? = Self.currentStorefrontCountry) {
        self.resolver = resolver
    }

    /// Always returns an alpha-2 code. `fallback` is normalized too, and when
    /// neither value can be mapped the result is "US" — the storefront the
    /// iTunes API assumes when no country is supplied.
    func region(fallback: String) async -> String {
        if let storefront = await resolver(), let alpha2 = ISOCountryCodes.alpha2(from: storefront) {
            return alpha2
        }
        return ISOCountryCodes.alpha2(from: fallback) ?? "US"
    }

    private static func currentStorefrontCountry() async -> String? {
        await Storefront.current?.countryCode
    }
}
