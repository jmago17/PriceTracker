import Foundation

/// Composition root. App Intents are instantiated by the system with a bare
/// `init()`, so they (and anything else that needs one) reach shared services
/// through this singleton rather than through injected initializers.
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()

    let itemStore: any PriceHistoryStoring
    /// Server-backed catalog. nil in demo/XCTest, where a local SQLite store is
    /// used and nothing touches the network.
    let remoteStore: RemoteItemStore?
    let settings: PriceBucketSettings

    /// The PriceBucket server checks prices and sends the alerts; the app only
    /// shows and edits the catalog.
    var isRemote: Bool { remoteStore != nil }

    init(
        isDemo: Bool = AppGroup.isDemo,
        settings: PriceBucketSettings = PriceBucketSettings.forApp(),
        transport: any PriceBucketTransport = URLSessionTransport(),
        databaseURL: URL = AppGroup.databaseURL,
        remoteCacheURL: URL = AppGroup.remoteCacheURL
    ) {
        self.settings = settings
        if isDemo {
            self.itemStore = SQLiteItemStore(databaseURL: databaseURL)
            self.remoteStore = nil
        } else {
            settings.migrateLegacyStorage()
            let remote = RemoteItemStore(
                cache: SQLiteItemStore(databaseURL: remoteCacheURL),
                client: PriceBucketClient(transport: transport, configuration: { try settings.configuration() }),
                settings: settings
            )
            self.itemStore = remote
            self.remoteStore = remote
        }
    }
}
