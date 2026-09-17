import SwiftUI

/// Home for the screens that used to be catalog-toolbar sheets with no other
/// entry point (handoff structural change #5). The catálogo "···" menu still
/// offers quick shortcuts to the same two screens for convenience.
struct SettingsView: View {
    var viewModel: ItemListViewModel
    var syncViewModel: SyncViewModel

    var body: some View {
        NavigationStack {
            List {
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
