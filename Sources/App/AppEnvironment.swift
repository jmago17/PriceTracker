import Foundation

/// Composition root. App Intents are instantiated by the system with a bare
/// `init()`, so they (and anything else that needs one) reach shared services
/// through this singleton rather than through injected initializers.
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()

    let itemStore: any ItemStoring
    let alertStore: any AlertStoring
    let connectors: ConnectorRegistry
    let refreshCoordinator: RefreshCoordinator
    let alertNotifier: AlertNotifier

    init(
        itemStore: any ItemStoring = JSONFileItemStore(fileURL: AppGroup.itemsFileURL),
        alertStore: any AlertStoring = JSONFileAlertStore(fileURL: AppGroup.alertsFileURL)
    ) {
        self.itemStore = itemStore
        self.alertStore = alertStore
        self.connectors = ConnectorRegistry()
        self.refreshCoordinator = RefreshCoordinator(itemStore: itemStore, alertStore: alertStore, connectors: connectors)
        self.alertNotifier = AlertNotifier(alertStore: alertStore, itemStore: itemStore)
    }
}
