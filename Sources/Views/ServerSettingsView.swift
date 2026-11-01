import SwiftUI

/// "Servidor PriceBucket": URL, API key (Keychain), connection test and sync.
/// Server URL, API key and manual sync.
struct ServerSettingsView: View {
    @Bindable var viewModel: RemoteSyncViewModel
    @State private var diagnostic: String?
    @State private var isDiagnosing = false

    var body: some View {
        Form {
            if !viewModel.isAvailable {
                Section {
                    Text("Modo de demostración: no hay conexión con el servidor.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField(PriceBucketSettings.defaultBaseURL.absoluteString, text: $viewModel.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("server-url-field")
                    SecureField(viewModel.isConfigured ? "Clave guardada · pega otra para cambiarla" : "Clave (x-key)",
                                text: $viewModel.apiKeyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .accessibilityIdentifier("server-key-field")
                    Button("Guardar") { Task { await viewModel.saveSettings() } }
                        .accessibilityIdentifier("server-save")
                    if let error = viewModel.settingsError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if viewModel.isConfigured {
                        Button("Quitar clave", role: .destructive) { Task { await viewModel.removeKey() } }
                    }
                } header: {
                    Text("Servidor PriceBucket")
                } footer: {
                    Text("La clave se guarda solo en el llavero de este dispositivo (la comparte la extensión de Compartir). El servidor comprueba los precios (cada día y en la rutina de las 08:00) y envía los avisos.")
                }

                Section {
                    Button {
                        Task { await viewModel.testConnection() }
                    } label: {
                        HStack {
                            Text("Probar conexión")
                            if viewModel.isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!viewModel.isConfigured || viewModel.isTesting)
                    if let message = viewModel.connectionMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                Section {
                    Button {
                        isDiagnosing = true
                        Task {
                            diagnostic = await NetworkDiagnostics.run(settings: PriceBucketSettings.forApp())
                            isDiagnosing = false
                        }
                    } label: {
                        HStack {
                            Text("Diagnóstico de red")
                            if isDiagnosing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isDiagnosing)
                    if let diagnostic {
                        Text(diagnostic).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } footer: {
                    Text("Prueba la red paso a paso (tarda hasta un minuto). Mantén pulsado el texto para copiarlo.")
                }

                Section {
                    LabeledContent("Última sincronización") {
                        Text(viewModel.lastSyncAt.map { $0.relativeSpanish } ?? "Nunca")
                    }
                    Button {
                        Task { await viewModel.sync() }
                    } label: {
                        HStack {
                            Text("Sincronizar ahora")
                            if viewModel.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!viewModel.isConfigured || viewModel.isSyncing)
                    .accessibilityIdentifier("server-sync-now")
                    if let error = viewModel.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                } header: {
                    Text("Sincronización")
                } footer: {
                    if !viewModel.isConfigured {
                        Text("Sin clave la app solo muestra lo que ya tiene guardado en este dispositivo.")
                    }
                }
            }
        }
        .navigationTitle("Servidor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}
