import SwiftUI

/// Home for the screens that used to be catalog-toolbar sheets with no other
/// entry point (handoff structural change #5). The catálogo "···" menu still
/// offers quick shortcuts to the same screens for convenience.
struct SettingsView: View {
    var viewModel: ItemListViewModel
    var syncViewModel: RemoteSyncViewModel

    @AppStorage("compactCatalogMuralEnabled") private var compactCatalogMuralEnabled = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                Section("Apariencia") {
                    Toggle("Mural en iPhone", isOn: $compactCatalogMuralEnabled)
                        .accessibilityIdentifier("compact-catalog-mural-toggle")
                    Text("Catálogo gris con tarjetas en dos columnas escalonadas, adaptable a una columna con texto accesible o poco ancho. Desactivado conserva la lista habitual. En iPad a ancho completo se mantiene el mural.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Atajos y Siri") {
                    Text("En Atajos: Buscar artículos → Repetir con cada uno → Actualizar artículo (pide al servidor que lo compruebe). Cada resultado incluye precio en céntimos, moneda, cambio y error.")
                    Text("Con Siri puedes decir: ‘Qué ha bajado en PriceTracker’. La disponibilidad depende del sistema, idioma y configuración de Siri.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {

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
        guard syncViewModel.isConfigured else { return "Sin configurar" }
        if let error = syncViewModel.lastError { return error }
        return syncViewModel.lastSyncAt.map { "Sincronizado \($0.relativeSpanish)" } ?? "Sin sincronizar"
    }

    /// Prices are checked and alerts sent by the server; the app has no
    /// on-device automation to configure.
    private var serverSection: some View {
        Section {
            NavigationLink {
                ServerSettingsView(viewModel: syncViewModel)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Servidor PriceBucket")
                        Text(syncSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
            }
            .accessibilityIdentifier("settings-sync-row")
        } header: {
            Text("Precios y avisos")
        } footer: {
            Text("El servidor comprueba los precios cada día (y en la rutina de las 08:00) y envía los avisos. La app solo muestra el catálogo y lo edita.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
