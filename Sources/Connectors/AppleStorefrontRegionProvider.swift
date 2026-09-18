import Foundation
import StoreKit

/// Resolves the App Store storefront attached to the signed-in Apple account.
/// Storefront country codes are ISO alpha-3 (for example USA); the iTunes
/// Search API accepts them directly. Tests and previews can inject a fixed value.
struct AppleStorefrontRegionProvider: Sendable {
    private let resolver: @Sendable () async -> String?

    init(resolver: @escaping @Sendable () async -> String? = Self.currentStorefrontCountry) {
        self.resolver = resolver
    }

    func region(fallback: String) async -> String {
        let candidate = await resolver()?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return candidate.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.uppercased()
    }

    private static func currentStorefrontCountry() async -> String? {
        await Storefront.current?.countryCode
    }
}
