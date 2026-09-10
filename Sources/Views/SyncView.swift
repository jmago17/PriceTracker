import SwiftUI

struct SyncView: View {
    @Bindable var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud") {
                    LabeledContent("Cuenta", value: viewModel.snapshot.accountState.rawValue)
                    LabeledContent("Última sincronización") {
                        Text(viewModel.snapshot.lastSuccessfulSync?.formatted(date: .abbreviated, time: .shortened) ?? "Nunca")
                    }
                    LabeledContent("Cambios locales pendientes", value: "\(viewModel.snapshot.pendingLocalChanges)")
                }

                if let error = viewModel.snapshot.lastError {
                    Section("Último error") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.syncNow() }
                    } label: {
                        if viewModel.snapshot.isSyncing {
                            HStack {
                                ProgressView()
                                Text("Sincronizando…")
                            }
                        } else {
                            Label("Sincronizar ahora", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                        }
                    }
                    .disabled(viewModel.snapshot.isSyncing)

                    Text("Los cambios se guardan primero en este dispositivo. Si iCloud no está disponible, permanecerán en cola y se reintentará sin bloquear la app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sincronización")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await viewModel.reload() }
        }
    }
}
