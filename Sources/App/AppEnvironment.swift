import Foundation

/// Composition root. App Intents are instantiated by the system with a bare
/// `init()`, so they (and anything else that needs one) reach shared services
/// through this singleton rather than through injected initializers.
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()

    let itemStore: any PriceHistoryStoring
    let localItemStore: SQLiteItemStore
    let syncManager: CloudSyncManager
    let syncStatusStore: CloudSyncStatusStore
    let alertStore: any AlertStoring
    let connectors: ConnectorRegistry
    let refreshCoordinator: RefreshCoordinator
    let alertNotifier: AlertNotifier
    /// Server-backed catalog. nil in demo/XCTest, where the local store is used
    /// and nothing touches the network.
    let remoteStore: RemoteItemStore?
    let settings: PriceBucketSettings

    /// Remote mode: the PriceBucket server checks prices and sends the alerts.
    /// The on-device RefreshCoordinator, daily task and Shortcuts bridge stay
    /// compiled (removed in phase 2b) but must not run.
    var isRemote: Bool { remoteStore != nil }

    init(
        alertStore: any AlertStoring = JSONFileAlertStore(fileURL: AppGroup.alertsFileURL),
        isDemo: Bool = AppGroup.isDemo,
        settings: PriceBucketSettings = PriceBucketSettings(),
        transport: any PriceBucketTransport = URLSessionTransport(),
        databaseURL: URL = AppGroup.databaseURL,
        remoteCacheURL: URL = AppGroup.remoteCacheURL
    ) {
        let localItemStore = SQLiteItemStore(databaseURL: databaseURL)
        let syncStatusStore = CloudSyncStatusStore()
        let syncManager = CloudSyncManager(
            localStore: localItemStore,
            legacyJSONURL: AppGroup.itemsFileURL,
            statusStore: syncStatusStore
        )
        self.localItemStore = localItemStore
        self.syncStatusStore = syncStatusStore
        self.syncManager = syncManager
        self.settings = settings
        if isDemo {
            self.itemStore = localItemStore
            self.remoteStore = nil
        } else {
            let remote = RemoteItemStore(
                cache: SQLiteItemStore(databaseURL: remoteCacheURL),
                client: PriceBucketClient(transport: transport, configuration: { try settings.configuration() }),
                settings: settings
            )
            self.itemStore = remote
            self.remoteStore = remote
        }
        self.alertStore = alertStore
        let connectors = ConnectorRegistry()
        self.connectors = connectors
        let notifier = AlertNotifier(alertStore: alertStore, itemStore: self.itemStore)
        self.alertNotifier = notifier
        self.refreshCoordinator = RefreshCoordinator(itemStore: self.itemStore, alertStore: alertStore, connectorToFetch: { store in
            #if DEBUG
            if AppGroup.isDemo && ProcessInfo.processInfo.arguments.contains("--demo-history") {
                return DemoHistoryConnector()
            }
            #endif
            return connectors.connectorToFetch(store: store)
        }, didRefresh: {
            // Reuse RootView's catalog revision observer for background/Shortcuts
            // checks too, including when the app already remains in the foreground.
            await syncStatusStore.catalogDidChange()
            _ = try? await notifier.notifyPendingDrops()
        })
    }
}

#if DEBUG
/// Used only by the explicitly synthetic UI fixture; never contacts a store.
private struct DemoHistoryConnector: StoreConnector {
    let store: Store = .appStore
    func canResolve(url: URL) -> Bool { false }
    func resolve(url: URL) async throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) async throws -> FetchResult {
        FetchResult(priceCents: 1299, currency: "EUR", isOnSale: false, availability: "available")
    }
}
#endif
