import SwiftUI
import UIKit

struct AddItemView: View {
    @State private var viewModel = AddItemViewModel()
    @Environment(\.dismiss) private var dismiss
    var onAdded: () async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    urlField
                    if viewModel.preview == nil && viewModel.errorMessage == nil {
                        actionButtons
                    }

                    if viewModel.isResolving {
                        resolvingCard
                    } else if let preview = viewModel.preview {
                        resolvedCard(preview)
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
                        .opacity(viewModel.preview == nil && viewModel.errorMessage == nil ? 1 : 0)
                }

            if viewModel.preview != nil || viewModel.errorMessage != nil {
                Button("Cambiar enlace") {
                    viewModel.reset()
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
                viewModel.lookUp()
            } label: {
                Label("Analizar enlace", systemImage: "magnifyingglass")
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
                Text("Leyendo la página…")
                    .font(.system(.body, weight: .semibold))
                Text("\(hostText) · buscando nombre y precio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func resolvedCard(_ preview: ResolvedItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AsyncImage(url: preview.imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                        .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(2)
                    if let subtitle = preview.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(storeCategoryText(preview))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            if let cents = preview.priceCents {
                Divider()
                HStack {
                    Text("Precio detectado")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(cents == 0 ? "Gratis" : format(cents, preview.currency))
                        .font(.system(.title3, weight: .bold))
                }
            } else {
                Divider()
                Label("Sin precio publicado", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Guardaremos el enlace, el nombre y la imagen. Podrás escribir el precio a mano cuando lo sepas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .modifier(AddButtonBelow(action: confirmAdd))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No hemos podido leer esta página", systemImage: "xmark.circle")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button("Reintentar") { viewModel.lookUp() }
                Button("Guardar solo el enlace") {
                    Task {
                        do {
                            _ = try await viewModel.saveLinkOnly()
                            await onAdded()
                            dismiss()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
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
            Text("App Store, Apple Books, Apple Music y Apple Store se comprueban de forma periódica. Cualquier otra URL se guarda con el precio del momento; si la tienda no lo publica, el enlace se guarda igualmente.")
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

    private func storeCategoryText(_ preview: ResolvedItem) -> String {
        if let genre = preview.storeGenre, !genre.isEmpty {
            return "\(preview.store.displayName) · \(genre)"
        }
        return preview.store.displayName
    }

    private func format(_ cents: Int, _ currency: String) -> String {
        String(format: "%.2f %@", Double(cents) / 100, currency)
    }

    private func confirmAdd() {
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
}

/// Keeps the "Añadir al catálogo" CTA visually tied to the resolved-preview
/// card without another indirection layer inside `resolvedCard`.
private struct AddButtonBelow: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        VStack(spacing: 12) {
            content
            Button(action: action) {
                Text("Añadir al catálogo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledFieldButtonStyle())
            .frame(height: 50)
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
