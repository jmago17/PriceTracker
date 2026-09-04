import Foundation

/// Central lookup: which connector (if any) handles a URL when adding an item,
/// and which one refreshes an existing item's price. eShop, PS Store and the
/// generic JSON-LD connector are Phase 2 per the architecture — not implemented,
/// not stubbed to look like they work.
final class ConnectorRegistry: Sendable {
    private let resolvers: [any StoreConnector]
    private let fetchersByStore: [Store: any StoreConnector]

    init() {
        let itunes = ITunesConnector()
        let amazon = AmazonConnector()
        resolvers = [itunes, amazon]
        fetchersByStore = [
            .appStore: itunes,
            .appleBooks: itunes,
            .appleMusic: itunes,
        ]
    }

    /// Tries every connector that knows how to add-by-URL. Amazon resolves (to
    /// capture the ASIN) but is not in `fetchersByStore` — it never auto-refreshes.
    func connectorToResolve(url: URL) -> (any StoreConnector)? {
        resolvers.first { $0.canResolve(url: url) }
    }

    func connectorToFetch(store: Store) -> (any StoreConnector)? {
        fetchersByStore[store]
    }
}
