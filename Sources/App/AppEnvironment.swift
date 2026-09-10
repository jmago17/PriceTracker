import Foundation

/// Composition root. App Intents are instantiated by the system with a bare
/// `init()`, so they (and anything else that needs one) reach shared services
/// through this singleton rather than through injected initializers.
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()

    let itemStore: any ItemStoring
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
        self.itemStore = itemStore
        self.alertStore = alertStore
        self.connectors = ConnectorRegistry()
        self.refreshCoordinator = RefreshCoordinator(itemStore: itemStore, alertStore: alertStore, connectors: connectors)
        self.alertNotifier = AlertNotifier(alertStore: alertStore, itemStore: itemStore)
    }
}
