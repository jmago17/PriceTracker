import Foundation

/// Level-A connector per the architecture: one API covers apps, books and music
/// with a single parameter. Not modeled: movies (architecture explicitly drops
/// "música"/"películas" as their own category — see /tmp/opus_architecture.md §a).
struct ITunesConnector: StoreConnector {
    /// `store` on the protocol is nominal; this connector actually serves three
    /// different `Store` values depending on what the URL points to (see `resolve`).
    let store: Store = .appStore

    private let session: URLSession
    private let defaultRegion: String

    init(session: URLSession = .shared, defaultRegion: String = "ES") {
        self.session = session
        self.defaultRegion = defaultRegion
    }

    func canResolve(url: URL) -> Bool {
        (try? Self.parseIdentity(from: url)) != nil
    }

    func resolve(url: URL) async throws -> ResolvedItem {
        let identity = try Self.parseIdentity(from: url)
        let result = try await lookup(id: identity.storeItemID, region: identity.region)
        return try makeResolvedItem(from: result, store: identity.store, region: identity.region, fallbackURL: url)
    }

    func fetch(_ item: Item) async throws -> FetchResult {
        let result = try await lookup(id: item.storeItemID, region: item.region)
        guard let priceCents = Self.priceCents(from: result) else {
            throw ConnectorError.decoding("La tienda no devolvió un precio para \(item.storeItemID)")
        }
        return FetchResult(
            priceCents: priceCents,
            currency: result.currency ?? item.currency,
            isOnSale: false,
            saleEndsAt: nil,
            availability: "available",
            title: result.trackName ?? result.collectionName,
            imageURL: Self.bestArtwork(result),
            storeGenre: result.primaryGenreName
        )
    }

    // MARK: - Identity parsing

    private struct Identity {
        var store: Store
        var storeItemID: String
        var region: String
    }

    private static func parseIdentity(from url: URL) throws -> Identity {
        guard let host = url.host, host.hasSuffix("apple.com") else { throw ConnectorError.unrecognizedURL }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let idSegment = segments.first(where: { $0.hasPrefix("id") && $0.dropFirst().allSatisfy(\.isNumber) }) else {
            throw ConnectorError.unrecognizedURL
        }
        let storeItemID = String(idSegment.dropFirst())

        let region = segments.first(where: { $0.count == 2 && $0.lowercased() == $0 && $0.allSatisfy(\.isLetter) })?.uppercased() ?? "ES"

        let store: Store
        if segments.contains("book") || segments.contains("books") {
            store = .appleBooks
        } else if host == "music.apple.com" {
            store = .appleMusic
        } else {
            store = .appStore
        }
        return Identity(store: store, storeItemID: storeItemID, region: region)
    }

    // MARK: - Lookup API

    private struct LookupResponse: Decodable {
        var resultCount: Int
        var results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        var trackId: Int?
        var collectionId: Int?
        var trackName: String?
        var collectionName: String?
        var artistName: String?
        var sellerName: String?
        var currency: String?
        var trackPrice: Double?
        var collectionPrice: Double?
        var primaryGenreName: String?
        var artworkUrl512: String?
        var artworkUrl100: String?
        var artworkUrl60: String?
        var trackViewUrl: String?
        var collectionViewUrl: String?
    }

    private func lookup(id: String, region: String) async throws -> LookupResult {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "country", value: region),
        ]
        guard let url = components.url else { throw ConnectorError.unrecognizedURL }

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw ConnectorError.network(error.localizedDescription)
        }

        let decoded: LookupResponse
        do {
            decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw ConnectorError.decoding(error.localizedDescription)
        }

        guard let first = decoded.results.first else { throw ConnectorError.notFound }
        return first
    }

    private func makeResolvedItem(from result: LookupResult, store: Store, region: String, fallbackURL: URL) throws -> ResolvedItem {
        guard let priceCents = Self.priceCents(from: result) else {
            throw ConnectorError.decoding("Sin precio en la respuesta de iTunes")
        }
        let storeItemID = String(result.trackId ?? result.collectionId ?? 0)
        let canonicalString = result.trackViewUrl ?? result.collectionViewUrl ?? fallbackURL.absoluteString
        return ResolvedItem(
            store: store,
            storeItemID: storeItemID,
            region: region,
            currency: result.currency ?? "EUR",
            canonicalURL: URL(string: canonicalString) ?? fallbackURL,
            title: result.trackName ?? result.collectionName ?? "Sin título",
            subtitle: result.artistName ?? result.sellerName,
            imageURL: Self.bestArtwork(result),
            priceCents: priceCents,
            priceReferenceCents: nil,
            storeGenre: result.primaryGenreName
        )
    }

    private static func priceCents(from result: LookupResult) -> Int? {
        guard let price = result.trackPrice ?? result.collectionPrice else { return nil }
        return Int((price * 100).rounded())
    }

    private static func bestArtwork(_ result: LookupResult) -> URL? {
        let candidate = result.artworkUrl512 ?? result.artworkUrl100 ?? result.artworkUrl60
        return candidate.flatMap(URL.init(string:))
    }
}
