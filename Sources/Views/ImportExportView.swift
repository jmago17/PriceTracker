import SwiftUI
import UniformTypeIdentifiers

private struct CatalogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ImportExportView: View {
    var viewModel: ItemListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: CatalogDocument?
    @State private var statusMessage: String?
    @State private var importMode: ImportMode = .merge

    var body: some View {
        NavigationStack {
            Form {
                Section("Exportar") {
                    Button("Exportar catálogo (JSON)") {
                        export()
                    }
                }

                Section("Importar") {
                    Picker("Modo", selection: $importMode) {
                        Text("Combinar").tag(ImportMode.merge)
                        Text("Reemplazar todo").tag(ImportMode.replace)
                    }
                    .pickerStyle(.segmented)

                    Button("Elegir fichero JSON…") {
                        isImporting = true
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                    }
                }

                Section {
                    Text("El formato es el propio de PriceTracker (schema v1). El export antiguo de Atajos aún no tiene mapeo — ver Sources/ImportExport/LegacyImport.swift.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Importar / exportar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "pricetracker-export"
            ) { result in
                switch result {
                case .success: statusMessage = "Exportado correctamente."
                case .failure(let error): statusMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
        }
    }

    private func export() {
        do {
            let data = try ItemExporter.exportData(items: viewModel.items)
            exportDocument = CatalogDocument(data: data)
            isExporting = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        Task {
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let summary = try await ItemImporter.importData(data, mode: importMode, into: AppEnvironment.shared.itemStore)
                statusMessage = "Importados \(summary.imported), omitidos \(summary.skipped)."
                await viewModel.load()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
