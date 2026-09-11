import Foundation

/// Last-resort resolver for any web store. It captures metadata once when the
/// item is added; generic items are deliberately not periodically scraped.
struct GenericStoreConnector: StoreConnector {
    let store: Store = .generic

    private let loader: StorePageLoader
    private let defaultRegion: String

    init(session: URLSession = .shared, defaultRegion: String = "ES") {
        loader = StorePageLoader(session: session)
        self.defaultRegion = defaultRegion
    }

    func canResolve(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        let metadata = try? await loader.load(url)
        let canonicalURL = metadata?.canonicalURL ?? Self.normalized(url)
        let title = metadata?.title ?? Self.fallbackTitle(for: canonicalURL)

        return ResolvedItem(
            store: .generic,
            storeItemID: canonicalURL.absoluteString,
            region: Self.region(from: canonicalURL) ?? defaultRegion,
            currency: metadata?.currency ?? "EUR",
            canonicalURL: canonicalURL,
            title: title,
            subtitle: metadata?.priceKind == .from
                ? "Precio desde"
                : metadata?.description ?? canonicalURL.host,
            imageURL: metadata?.imageURL,
            priceCents: metadata?.priceCents,
            priceReferenceCents: nil,
            storeGenre: nil
        )
    }

    func fetch(_ item: Item) async throws -> FetchResult {
        throw ConnectorError.notSupported(
            "Este enlace se guarda con la información disponible al añadirlo, sin seguimiento automático de precio."
        )
    }

    private static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func fallbackTitle(for url: URL) -> String {
        let decodedComponent = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let component = decodedComponent
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !component.isEmpty { return component }
        return url.host ?? url.absoluteString
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
}
