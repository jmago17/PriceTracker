import SwiftUI

struct RootView: View {
    @State private var viewModel = ItemListViewModel()
    @State private var showingAddItem = false
    @State private var showingImportExport = false
    @State private var showingSharedInbox = false
    @State private var sharedInbox = SharedInboxViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let progress = viewModel.refreshProgress, viewModel.isRefreshingCatalog {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            Text(progress.currentTitle.map { "Comprobando: \($0)" } ?? "Comprobando catálogo…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(viewModel.itemsByCategory, id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            NavigationLink(value: item.id) {
                                ItemRowView(item: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { viewModel.delete(group.items[index]) }
                        }
                    } header: {
                        HStack {
                            Text(group.category ?? "Sin categoría")
                            Spacer()
                            Button {
                                viewModel.refreshCategory(group.category)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if viewModel.items.isEmpty {
                    ContentUnavailableView(
                        "Sin artículos",
                        systemImage: "cart",
                        description: Text("Añade uno con el botón +")
                    )
                }
            }
            .navigationTitle("PriceTracker")
            .searchable(text: $viewModel.searchText)
            .navigationDestination(for: UUID.self) { id in
                if let item = viewModel.items.first(where: { $0.id == id }) {
                    ItemDetailView(item: item, viewModel: viewModel)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Importar / exportar", systemImage: "square.and.arrow.up.on.square") {
                            showingImportExport = true
                        }
                        Button("Enlaces compartidos", systemImage: "square.and.arrow.down") {
                            sharedInbox.reload()
                            showingSharedInbox = true
                        }
                        if viewModel.isRefreshingCatalog {
                            Button("Cancelar actualización", systemImage: "xmark", role: .destructive) {
                                viewModel.cancelRefreshCatalog()
                            }
                        } else {
                            Button("Actualizar todo", systemImage: "arrow.clockwise") {
                                viewModel.startRefreshCatalog()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAddItem) {
                AddItemView(onAdded: { await viewModel.load() })
            }
            .sheet(isPresented: $showingImportExport) {
                ImportExportView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingSharedInbox) {
                SharedInboxView(viewModel: sharedInbox) { await viewModel.load() }
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { viewModel.lastErrorMessage != nil },
                    set: { if !$0 { viewModel.lastErrorMessage = nil } }
                )
            ) {
                Button("OK") { viewModel.lastErrorMessage = nil }
            } message: {
                Text(viewModel.lastErrorMessage ?? "")
            }
            .task {
                await sharedInbox.processAll()
                await viewModel.load()
            }
            .refreshable { await viewModel.load() }
        }
    }
}

#Preview {
    RootView()
}
