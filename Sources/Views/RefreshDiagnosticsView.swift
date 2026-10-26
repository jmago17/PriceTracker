import SwiftUI

struct RefreshDiagnosticsView: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var report = "Cargando diagnóstico…"
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Este registro solo vive en la memoria de esta sesión. Se borra al cerrar el proceso y caduca a las 24 horas. No contiene el enlace ni el nombre del artículo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LabeledContent("Último éxito", value: item.lastSuccessAt?.formatted(date: .abbreviated, time: .standard) ?? "Sin éxito registrado")
                    LabeledContent("Último intento guardado", value: item.lastCheckedAt?.formatted(date: .abbreviated, time: .standard) ?? "Sin intento registrado")
                    Text("Un intento o una alerta pendiente no renuevan la fecha del último éxito. Los fallos anteriores a esta versión no pueden reconstruirse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(report)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLoaded {
                        ShareLink(item: report, subject: Text("Diagnóstico de Price Bucket")) {
                            Label("Compartir informe…", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("share-refresh-diagnostics")
                        Button("Borrar diagnóstico de este artículo", role: .destructive) {
                            Task {
                                await RefreshDiagnostics.shared.clear(itemID: item.id)
                                await reload()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Diagnóstico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Recargar", systemImage: "arrow.clockwise") {
                        Task { await reload() }
                    }
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        let attempts = await RefreshDiagnostics.shared.snapshot(itemID: item.id)
        report = RefreshDiagnostics.report(attempts)
        isLoaded = true
    }
}
