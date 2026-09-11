import Foundation

/// Central lookup: which connector (if any) handles a URL when adding an item,
/// and which one refreshes an existing item's price. eShop, PS Store and the
/// generic JSON-LD connector are Phase 2 per the architecture — not implemented,
/// not stubbed to look like they work.
final class ConnectorRegistry: Sendable {
    private let resolvers: [any StoreConnector]
    private let fetchersByStore: [Store: any StoreConnector]

    convenience init() {
        let itunes = ITunesConnector()
        let appleStore = AppleStoreConnector()
        let amazon = AmazonConnector()
        let generic = GenericStoreConnector()
        self.init(resolvers: [itunes, appleStore, amazon, generic], fetchersByStore: [
            .appStore: itunes,
            .appleStore: appleStore,
            .appleBooks: itunes,
            .appleMusic: itunes,
        ])
    }

    init(resolvers: [any StoreConnector], fetchersByStore: [Store: any StoreConnector] = [:]) {
        self.resolvers = resolvers
        self.fetchersByStore = fetchersByStore
    }

    /// Tries every connector that knows how to add-by-URL. Amazon resolves (to
    /// capture the ASIN) but is not in `fetchersByStore` — it never auto-refreshes.
    func resolve(url: URL) async throws -> ResolvedItem {
        let candidates = resolvers.filter { $0.canResolve(url: url) }
        guard !candidates.isEmpty else { throw ConnectorError.unrecognizedURL }

        var lastError: Error = ConnectorError.unrecognizedURL
        for connector in candidates {
            do {
                return try await connector.resolve(url: url)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func connectorToFetch(store: Store) -> (any StoreConnector)? {
        fetchersByStore[store]
    }
}
