import SwiftUI

struct AddItemView: View {
    @State private var viewModel = AddItemViewModel()
    @Environment(\.dismiss) private var dismiss
    var onAdded: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("URL de cualquier tienda…", text: $viewModel.urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Buscar") {
                        viewModel.lookUp()
                    }
                    .disabled(viewModel.urlText.isEmpty || viewModel.isResolving)
                }

                if viewModel.isResolving {
                    ProgressView()
                }

                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                if let preview = viewModel.preview {
                    Section("Vista previa") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.title).font(.headline)
                            if let subtitle = preview.subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(preview.store.displayName).font(.caption).foregroundStyle(.secondary)
                            if let cents = preview.priceCents {
                                Text(String(format: "%.2f %@", Double(cents) / 100, preview.currency))
                            } else {
                                Text("Sin precio disponible; el enlace se guardará igualmente.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Añadir artículo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") {
                        Task {
                            do {
                                _ = try await viewModel.confirmAdd()
                                await onAdded()
                                dismiss()
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(viewModel.preview == nil)
                }
            }
        }
    }
}
