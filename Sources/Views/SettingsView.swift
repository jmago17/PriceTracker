import SwiftUI

/// Home for the screens that used to be catalog-toolbar sheets with no other
/// entry point (handoff structural change #5). The catálogo "···" menu still
/// offers quick shortcuts to the same two screens for convenience.
struct SettingsView: View {
    var viewModel: ItemListViewModel
    var syncViewModel: SyncViewModel

    @State private var automation = DailyRefreshSettings.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Actualizar precios diariamente", isOn: Binding(
                        get: { automation.dailyEnabled }, set: { automation.setDailyEnabled($0) }))
                    Toggle("Notificar cambios de precio", isOn: Binding(
                        get: { automation.notificationsEnabled },
                        set: { value in Task { await automation.setNotificationsEnabled(value) } }))
                        .disabled(automation.requestingPermission)
                    if let message = automation.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Precios y avisos")
                } footer: {
                    Text("iOS decide cuándo puede actualizar en segundo plano; no se garantiza una hora ni una ejecución diaria. Solo se comprueban tiendas compatibles. Los avisos también se aplican a las comprobaciones manuales y de Atajos.")
                }
                Section("Atajos y Siri") {
                    Text("En Atajos: Buscar artículos → Repetir con cada uno → Actualizar artículo. Cada resultado incluye precio en céntimos, moneda, cambio y error.")
                    Text("Con Siri puedes decir: ‘Comprueba los precios en PriceTracker’. La disponibilidad depende del sistema, idioma y configuración de Siri.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        SyncView(viewModel: syncViewModel)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sincronización")
                                Text(syncSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "icloud")
                        }
                    }
                    .accessibilityIdentifier("settings-sync-row")

                    NavigationLink {
                        ImportExportView(viewModel: viewModel)
                    } label: {
                        Label("Importar / exportar", systemImage: "square.and.arrow.up.on.square")
                    }
                }

                Section {
                    LabeledContent("Versión", value: appVersion)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    private var syncSubtitle: String {
        let pending = syncViewModel.snapshot.pendingLocalChanges
        if syncViewModel.snapshot.accountState == .signedOut { return "Sesión cerrada" }
        return pending > 0 ? "\(pending) cambios pendientes" : "Al día"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
