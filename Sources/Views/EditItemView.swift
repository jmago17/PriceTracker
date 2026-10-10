import SwiftUI

/// The ficha stopped auto-saving on every keystroke (handoff, structural change
/// #3): edits now happen here, in a sheet, and commit only on "Guardar".
struct EditItemView: View {
    let item: Item
    var viewModel: ItemListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var category: String
    @State private var targetPriceText: String
    @State private var notes: String
    @State private var tagsText: String
    @State private var size: String
    @State private var color: String
    @State private var summary: String

    init(item: Item, viewModel: ItemListViewModel) {
        self.item = item
        self.viewModel = viewModel
        _category = State(initialValue: item.category ?? "")
        _targetPriceText = State(initialValue: item.targetPriceCents.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _notes = State(initialValue: item.notes ?? "")
        _tagsText = State(initialValue: (item.tags ?? []).joined(separator: ", "))
        _size = State(initialValue: item.size ?? "")
        _color = State(initialValue: item.color ?? "")
        _summary = State(initialValue: item.summary ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Categoría") {
                    TextField("Categoría", text: $category)
                    if item.categorySource == .mapped {
                        Text("Sugerida por la tienda (\(item.storeGenre ?? "")) — se puede sobrescribir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Talla", text: $size)
                    TextField("Color", text: $color)
                } header: {
                    Text("Variante")
                } footer: {
                    Text("Se incluye al compartir el artículo.")
                }

                Section("Resumen") {
                    TextField("Sin resumen", text: $summary, axis: .vertical)
                        .lineLimit(3...10)
                }

                Section("Precio objetivo") {
                    TextField("Sin definir", text: $targetPriceText)
                        .keyboardType(.decimalPad)
                }

                Section("Etiquetas") {
                    TextField("Separadas por comas", text: $tagsText)
                }

                Section("Notas") {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
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
        updated.size = size.trimmedNonEmpty
        updated.color = color.trimmedNonEmpty
        updated.summary = summary.trimmedNonEmpty
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.tags = tags.isEmpty ? nil : Array(Set(tags)).sorted()
        updated.updatedAt = Date()
        guard updated != item else { return }
        viewModel.save(updated)
    }
}
