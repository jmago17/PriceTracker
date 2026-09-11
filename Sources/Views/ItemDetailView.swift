import SwiftUI

struct ItemDetailView: View {
    let item: Item
    var viewModel: ItemListViewModel

    @State private var category: String
    @State private var targetPriceText: String
    @State private var notes: String
    @State private var tagsText: String
    @State private var isRefreshing = false

    init(item: Item, viewModel: ItemListViewModel) {
        self.item = item
        self.viewModel = viewModel
        _category = State(initialValue: item.category ?? "")
        _targetPriceText = State(initialValue: item.targetPriceCents.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _notes = State(initialValue: item.notes ?? "")
        _tagsText = State(initialValue: (item.tags ?? []).joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AsyncImage(url: item.imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading) {
                        Text(item.title).font(.headline)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(item.store.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Precio") {
                LabeledContent("Actual", value: item.priceCurrentCents.map(formatCents) ?? "—")
                LabeledContent("Al añadirlo", value: item.priceAtAddCents.map(formatCents) ?? "—")
                if let low = item.priceLowCents {
                    LabeledContent("Mínimo histórico", value: formatCents(low))
                }
                TextField("Precio objetivo", text: $targetPriceText)
                    .keyboardType(.decimalPad)
            }

            Section("Categoría") {
                TextField("Categoría", text: $category)
                if item.categorySource == .mapped {
                    Text("Sugerida por la tienda (\(item.storeGenre ?? "")) — se puede sobrescribir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Estado") {
                LabeledContent("Estado", value: item.status.displayName)
                if let lastChecked = item.lastCheckedAt {
                    LabeledContent("Última comprobación", value: lastChecked.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = item.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if item.store == .amazon {
                    Link(
                        "Ver en Keepa",
                        destination: AmazonConnector.keepaURL(asin: item.storeItemID, region: item.region)
                    )
                }
            }

            Section("Notas") {
                TextField("Etiquetas separadas por comas", text: $tagsText)
                TextField("Notas", text: $notes, axis: .vertical)
            }

            Section {
                Button {
                    refresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Actualizar ahora", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!Store.refreshableStores.contains(item.store) || isRefreshing)

                Button("Ver en la tienda", systemImage: "arrow.up.right") {
                    openInStore()
                }

                Button("Eliminar", systemImage: "trash", role: .destructive) {
                    viewModel.delete(item)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: category) { _, _ in saveEdits() }
        .onChange(of: targetPriceText) { _, _ in saveEdits() }
        .onChange(of: notes) { _, _ in saveEdits() }
        .onChange(of: tagsText) { _, _ in saveEdits() }
    }

    private func refresh() {
        isRefreshing = true
        viewModel.refreshSingle(item)
        Task {
            try? await Task.sleep(for: .seconds(1))
            isRefreshing = false
        }
    }

    private func openInStore() {
        #if canImport(UIKit)
        UIApplication.shared.open(item.canonicalURL)
        #endif
    }

    private func saveEdits() {
        var updated = item
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.category = trimmedCategory.isEmpty ? nil : trimmedCategory
        if updated.category != item.category {
            updated.categorySource = trimmedCategory.isEmpty ? .none : .manual
        }
        if let value = Double(targetPriceText.replacingOccurrences(of: ",", with: ".")) {
            updated.targetPriceCents = Int((value * 100).rounded())
        } else {
            updated.targetPriceCents = nil
        }
        updated.notes = notes.isEmpty ? nil : notes
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.tags = tags.isEmpty ? nil : Array(Set(tags)).sorted()
        updated.updatedAt = Date()
        guard updated != item else { return }
        viewModel.save(updated)
    }

    private func formatCents(_ cents: Int) -> String {
        String(format: "%.2f %@", Double(cents) / 100, item.currency)
    }
}
