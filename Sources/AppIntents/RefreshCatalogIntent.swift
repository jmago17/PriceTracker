import AppIntents
import Foundation

struct RefreshCatalogIntent: AppIntent {
    static let title: LocalizedStringResource = "Comprobar precios"
    static let description = IntentDescription("Comprueba de nuevo el precio de todos los artículos activos.", categoryName: "Actualizar")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true
    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        if let remote = AppEnvironment.shared.remoteStore {
            // The server checks prices; this pulls its latest state.
            guard remote.isConfigured else { throw PriceBucketError.notConfigured }
            try await remote.sync()
            let items = try await remote.loadAll()
            let dropped = ShowPriceDropsIntent.discountedItems(in: items).count
            return .result(value: dropped, dialog: IntentDialog(stringLiteral:
                "Catálogo sincronizado: \(items.count) artículos, \(dropped) con precio por debajo del inicial. Los precios los comprueba el servidor."))
        }
        let summary = try await AppEnvironment.shared.refreshCoordinator.refreshCatalog()
        return .result(value: summary.dropped, dialog: IntentDialog(stringLiteral: Self.spokenSummary(for: summary)))
    }

    static func spokenSummary(for summary: RefreshSummary) -> String {
        if summary.skipped > 0 || summary.cancelled { return summary.completionMessage }
        if summary.failed > 0 { return "Comprobados \(summary.checked) artículos: \(summary.dropped) con bajadas y \(summary.failed) errores. Omitidos: \(summary.skipped)." }
        if summary.checked == 0 { return "No hay artículos que comprobar." }
        if summary.dropped == 0 { return "Comprobados \(summary.checked) artículos. Ninguno ha bajado." }
        if summary.dropped == 1 { return "Comprobados \(summary.checked) artículos. Uno ha bajado de precio." }
        return "Comprobados \(summary.checked) artículos. \(summary.dropped) han bajado de precio."
    }
}
