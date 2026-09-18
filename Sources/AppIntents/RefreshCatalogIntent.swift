import AppIntents
import Foundation

struct RefreshCatalogIntent: AppIntent {
    static let title: LocalizedStringResource = "Comprobar precios"
    static let description = IntentDescription("Comprueba de nuevo el precio de todos los artículos activos.", categoryName: "Actualizar")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true
    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let summary = try await AppEnvironment.shared.refreshCoordinator.refreshCatalog()
        return .result(value: summary.dropped, dialog: IntentDialog(stringLiteral: Self.spokenSummary(for: summary)))
    }

    static func spokenSummary(for summary: RefreshSummary) -> String {
        if summary.checked == 0 { return "No hay artículos que comprobar." }
        if summary.dropped == 0 { return "Comprobados \(summary.checked) artículos. Ninguno ha bajado." }
        if summary.dropped == 1 { return "Comprobados \(summary.checked) artículos. Uno ha bajado de precio." }
        return "Comprobados \(summary.checked) artículos. \(summary.dropped) han bajado de precio."
    }
}
