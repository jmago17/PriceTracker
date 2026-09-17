import SwiftUI
import UIKit

struct SyncView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                syncNowButton
                Text("Los cambios se guardan primero en este dispositivo y se envían cuando iCloud está disponible. Puedes seguir usando la app sin conexión.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Signed-out already explains itself inline in statusCard —
                // showing the raw sync failure on top of it would say the same
                // thing twice.
                if let error = viewModel.snapshot.lastError, viewModel.snapshot.accountState != .signedOut {
                    errorSection(error)
                }
            }
            .padding(20)
            .padding(.bottom, 60)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sincronización")
        .navigationBarTitleDisplayMode(.large)
        .task { await viewModel.reload() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: accountIcon)
                    .font(.title2)
                    .foregroundStyle(accountColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(accountHeadline)
                        .font(.system(.body, weight: .semibold))
                    Text(lastSyncText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if viewModel.snapshot.accountState == .signedOut {
                        Text("El catálogo funciona igual en este iPhone. Inicia sesión en Ajustes para verlo también en tus otros dispositivos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Button("Abrir Ajustes de iCloud") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.subheadline)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 12)
            Divider()
            HStack {
                Text("Cambios pendientes")
                Spacer()
                Text(pendingText).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var syncNowButton: some View {
        Button {
            Task { await viewModel.syncNow() }
        } label: {
            HStack {
                Spacer()
                if viewModel.snapshot.isSyncing {
                    ProgressView()
                    Text("Sincronizando…")
                } else {
                    Label("Sincronizar ahora", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
            .frame(height: 48)
        }
        .disabled(viewModel.snapshot.isSyncing)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ÚLTIMO PROBLEMA")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Un cambio no se pudo enviar", systemImage: "exclamationmark.circle")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Se reintentará solo. El producto sigue guardado aquí.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label("Copiar detalle del error", systemImage: "doc.on.doc")
                }
                .font(.subheadline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var accountHeadline: String {
        switch viewModel.snapshot.accountState {
        case .available: return "iCloud activo"
        case .checking: return "Comprobando iCloud…"
        case .signedOut: return "Sesión de iCloud cerrada"
        default: return viewModel.snapshot.accountState.rawValue
        }
    }

    private var accountIcon: String {
        switch viewModel.snapshot.accountState {
        case .available: return "checkmark.icloud.fill"
        case .signedOut: return "icloud.slash"
        case .checking: return "icloud"
        default: return "exclamationmark.icloud"
        }
    }

    private var accountColor: Color {
        switch viewModel.snapshot.accountState {
        case .available: return .green
        case .signedOut, .checking: return .secondary
        default: return .orange
        }
    }

    private var lastSyncText: String {
        guard let date = viewModel.snapshot.lastSuccessfulSync else { return "Sin sincronizar todavía" }
        // "Sincronizado" implies an active session; signed-out only ever means
        // a past send, so it gets its own honest wording.
        let verb = viewModel.snapshot.accountState == .signedOut ? "Último envío" : "Sincronizado"
        return "\(verb) \(date.relativeSpanish)"
    }

    private var pendingText: String {
        let count = viewModel.snapshot.pendingLocalChanges
        return count == 0 ? "Ninguno" : "\(count) en este dispositivo"
    }
}
