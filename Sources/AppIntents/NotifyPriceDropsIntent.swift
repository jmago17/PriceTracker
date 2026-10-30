import AppIntents
import Foundation

/// Retry delivery of pending changes; uses the same opt-in and delivery gate.
struct NotifyPriceDropsIntent: AppIntent {
    static let title: LocalizedStringResource = "Notificar cambios de precio"
    static let description = IntentDescription("Reintenta los avisos pendientes si están activados en Ajustes. Las actualizaciones ya notifican automáticamente.")
    static let supportedModes: IntentModes = .background

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        // Remote mode: the server sends the alerts; the app has nothing pending.
        if AppEnvironment.shared.isRemote { return .result(value: 0) }
        let count = try await AppEnvironment.shared.alertNotifier.notifyPendingDrops()
        return .result(value: count)
    }
}
