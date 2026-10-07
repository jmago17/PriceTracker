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

    init(alertStore: any AlertStoring = JSONFileAlertStore(fileURL: AppGroup.alertsFileURL)) {
        let localItemStore = SQLiteItemStore(databaseURL: AppGroup.databaseURL)
        let syncStatusStore = CloudSyncStatusStore()
        let syncManager = CloudSyncManager(
            localStore: localItemStore,
            legacyJSONURL: AppGroup.itemsFileURL,
            statusStore: syncStatusStore
        )
        let itemStore = CloudBackedItemStore(
            localStore: localItemStore,
            syncManager: syncManager,
            legacyJSONURL: AppGroup.itemsFileURL
        )
        self.localItemStore = localItemStore
        self.syncStatusStore = syncStatusStore
        self.syncManager = syncManager
        if AppGroup.isDemo {
            self.itemStore = localItemStore
        } else {
            self.itemStore = itemStore
        }
        self.alertStore = alertStore
        let connectors = ConnectorRegistry()
        self.connectors = connectors
        self.refreshCoordinator = RefreshCoordinator(itemStore: self.itemStore, alertStore: alertStore, connectorToFetch: { store in
            #if DEBUG
            if AppGroup.isDemo && ProcessInfo.processInfo.arguments.contains("--demo-history") {
                return DemoHistoryConnector()
            }
            #endif
            return connectors.connectorToFetch(store: store)
        })
        self.alertNotifier = AlertNotifier(alertStore: alertStore, itemStore: self.itemStore)
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
