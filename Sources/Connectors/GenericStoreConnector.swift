import Foundation

/// Last-resort resolver for any web store. It captures metadata once when the
/// item is added; generic items are deliberately not periodically scraped.
struct GenericStoreConnector: StoreConnector {
    let store: Store = .generic

    private let loader: StorePageLoader
    private let defaultRegion: String
    private let rendersDynamicPages: Bool

    init(
        session: URLSession = .shared,
        defaultRegion: String = "ES",
        rendersDynamicPages: Bool = true
    ) {
        loader = StorePageLoader(session: session)
        self.defaultRegion = defaultRegion
        self.rendersDynamicPages = rendersDynamicPages
    }

    func canResolve(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        try await resolve(url: url, pageCapture: nil)
    }

    func resolve(url: URL, pageCapture: SharedPageCapture?) async throws -> ResolvedItem {
        let metadata = try? await loader.load(url)
        let renderedCapture: SharedPageCapture?
        if let pageCapture, !pageCapture.isLikelyAccessInterruption {
            renderedCapture = pageCapture
        } else if rendersDynamicPages, Self.needsRenderedFallback(metadata) {
            renderedCapture = try? await RenderedPageCaptureLoader().load(url)
        } else {
            renderedCapture = nil
        }

        let canonicalURL = renderedCapture?.canonicalURL
            ?? metadata?.canonicalURL
            ?? Self.normalized(url)
        let title = renderedCapture?.title
            ?? metadata?.title
            ?? Self.fallbackTitle(for: canonicalURL)
        let description = renderedCapture?.description ?? metadata?.description
        let priceCents = renderedCapture?.priceCents ?? metadata?.priceCents
        let currency = renderedCapture?.currency ?? metadata?.currency ?? "EUR"
        let category = renderedCapture?.category ?? metadata?.category

        return ResolvedItem(
            store: .generic,
            storeItemID: canonicalURL.absoluteString,
            region: Self.region(from: canonicalURL) ?? defaultRegion,
            currency: currency,
            canonicalURL: canonicalURL,
            title: title,
            subtitle: metadata?.priceKind == .from
                ? "Precio desde"
                : description ?? canonicalURL.host,
            imageURL: renderedCapture?.imageURL ?? metadata?.imageURL,
            priceCents: priceCents,
            priceReferenceCents: nil,
            storeGenre: category
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

    private static func needsRenderedFallback(_ metadata: StorePageMetadata?) -> Bool {
        guard let metadata else { return true }
        return metadata.priceCents == nil || metadata.imageURL == nil
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
