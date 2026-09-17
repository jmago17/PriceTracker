import SwiftUI
import UIKit

struct SharedInboxView: View {
    @Bindable var viewModel: SharedInboxViewModel
    var onChanged: () async -> Void

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Bandeja")
            .toolbar {
                if !viewModel.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reintentar todos") {
                            Task { await viewModel.processAll(); await onChanged() }
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }
            }
            .task {
                await viewModel.processAll()
                await onChanged()
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(viewModel.entries) { entry in
                    entryRow(entry)
                }
                .onDelete { offsets in
                    for index in offsets { viewModel.delete(viewModel.entries[index]) }
                }
            } header: {
                Text("\(viewModel.entries.count) enlaces recibidos desde Compartir")
            } footer: {
                Text("Desliza un enlace para eliminarlo. Los enlaces resueltos pasan al catálogo automáticamente.")
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SharedURLInbox.Entry) -> some View {
        if viewModel.processingEntryID == entry.id {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resolviendo…")
                        .foregroundStyle(.secondary)
                    Text(entry.urlString)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        } else if let error = entry.lastError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(entry.urlString)
                    .font(.callout)
                    .lineLimit(2)
                Text(receivedText(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.retry(entry); await onChanged() }
                    } label: {
                        Label("Reintentar", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GhostChipButtonStyle())

                    if let url = URL(string: entry.urlString) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Text("Abrir enlace")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GhostChipButtonStyle(tint: .secondary))
                    }
                }
                .frame(height: 40)
            }
            .padding(.vertical, 6)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { viewModel.delete(entry) } label: {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        } else {
            Text(entry.urlString)
                .font(.callout)
                .lineLimit(2)
                .padding(.vertical, 6)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { viewModel.delete(entry) } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                }
        }
    }

    private func receivedText(_ entry: SharedURLInbox.Entry) -> String {
        let when = entry.receivedAt.shortTimeSpanish
        let attempts = entry.attempts ?? 0
        return "Recibido \(entry.receivedAt.relativeSpanish), \(when) · \(attempts) intento\(attempts == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Todo procesado",
            systemImage: "checkmark.circle",
            description: Text("Los enlaces que compartas desde Safari u otra app aparecerán aquí y pasarán al catálogo en cuanto se resuelvan.")
        )
    }
}

private struct GhostChipButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .background(tint == .secondary ? Color(.tertiarySystemFill) : tint.opacity(configuration.isPressed ? 0.18 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
