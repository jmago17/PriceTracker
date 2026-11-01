import SwiftUI
import UIKit

struct AddItemView: View {
    @State private var viewModel = AddItemViewModel()
    @Environment(\.dismiss) private var dismiss
    var onAdded: (Item) async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    urlField
                    if viewModel.errorMessage == nil {
                        actionButtons
                    }

                    if viewModel.isResolving {
                        resolvingCard
                    } else if let error = viewModel.errorMessage {
                        errorCard(error)
                    } else {
                        infoFooter
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Añadir producto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pega el enlace de la tienda")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://…", text: $viewModel.urlText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(viewModel.errorMessage == nil ? 1 : 0)
                }

            if viewModel.errorMessage != nil {
                Button("Cambiar enlace") {
                    viewModel.errorMessage = nil
                }
                .font(.subheadline)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                if let text = UIPasteboard.general.string {
                    viewModel.urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Label("Pegar", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostFieldButtonStyle())

            Button {
                add()
            } label: {
                Label("Añadir enlace", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledFieldButtonStyle())
            .disabled(viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(height: 46)
    }

    private var resolvingCard: some View {
        HStack(spacing: 14) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Enviando al servidor…")
                    .font(.system(.body, weight: .semibold))
                Text("\(hostText) · el servidor busca nombre y precio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No se pudo añadir el enlace", systemImage: "xmark.circle")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Reintentar") { add() }
                .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var infoFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CÓMO FUNCIONA")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("El servidor lee la página y comprueba el precio cada día. App Store y las webs legibles se resuelven al momento; Amazon y las webs bloqueadas quedan pendientes de la primera comprobación (08:00).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var hostText: String {
        URL(string: viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "la tienda"
    }

    private func add() {
        viewModel.errorMessage = nil
        Task {
            do {
                let item = try await viewModel.add()
                await onAdded(item)
                dismiss()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FilledFieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 46)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct GhostFieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(height: 46)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
