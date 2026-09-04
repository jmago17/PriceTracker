import AppIntents
import Foundation

/// Called once, at the end of the Shortcuts automation (after the
/// "Repeat with each → RefreshItem" loop), so the user gets one summary
/// notification instead of one per item. See Alerts/AlertNotifier.swift.
struct NotifyPriceDropsIntent: AppIntent {
    static let title: LocalizedStringResource = "Notificar bajadas de precio"
    static let description = IntentDescription("Envía un resumen de las bajadas de precio pendientes y las marca como notificadas.")
    static let supportedModes: IntentModes = .background

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let count = try await AppEnvironment.shared.alertNotifier.notifyPendingDrops()
        return .result(value: count)
    }
}
