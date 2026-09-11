import Foundation

/// Resolves public Apple Online Store product pages from their JSON-LD product
/// metadata. Configured products expose an exact `Offer`; family pages expose
/// an `AggregateOffer`, whose low price is explicitly kept as a "from" price.
struct AppleStoreConnector: StoreConnector {
    let store: Store = .appleStore

    private let session: URLSession
    private let defaultRegion: String

    init(session: URLSession = .shared, defaultRegion: String = "ES") {
        self.session = session
        self.defaultRegion = defaultRegion
    }

    func canResolve(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "store.apple.com" {
            return url.path.lowercased().contains("/product/")
        }
        guard host == "apple.com" || host == "www.apple.com" else { return false }
        return url.path.lowercased().contains("/shop/")
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        let product = try await loadProduct(from: url)
        let canonicalURL = product.canonicalURL
        let region = Self.region(from: canonicalURL) ?? defaultRegion
        guard let priceCents = product.priceCents,
              let currency = product.currency else {
            throw ConnectorError.decoding("Apple Store no publicó un precio para este enlace")
        }

        return ResolvedItem(
            store: .appleStore,
            storeItemID: product.sku ?? Self.pathIdentity(for: canonicalURL),
            region: region,
            currency: currency,
            canonicalURL: canonicalURL,
            title: product.title,
            subtitle: product.priceKind == .from ? "Precio desde" : "Apple Store",
            imageURL: product.imageURL,
            priceCents: priceCents,
            priceReferenceCents: nil,
            storeGenre: "Hardware"
        )
    }

    func fetch(_ item: Item) async throws -> FetchResult {
        let product = try await loadProduct(from: item.canonicalURL)
        guard let priceCents = product.priceCents,
              let currency = product.currency else {
            throw ConnectorError.decoding("Apple Store no publicó un precio para este enlace")
        }
        return FetchResult(
            priceCents: priceCents,
            currency: currency,
            isOnSale: false,
            saleEndsAt: nil,
            availability: "available",
            title: product.title,
            imageURL: product.imageURL,
            storeGenre: "Hardware"
        )
    }

    private func loadProduct(from url: URL) async throws -> StorePageMetadata {
        try await StorePageLoader(session: session).load(url)
    }

    private static func region(from url: URL) -> String? {
        url.pathComponents
            .first { component in
                component.count == 2
                    && component.lowercased() == component
                    && component.allSatisfy(\.isLetter)
            }?
            .uppercased()
    }

    private static func pathIdentity(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? url.absoluteString : path
    }
}
