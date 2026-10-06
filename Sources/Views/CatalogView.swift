import SwiftUI

struct CatalogView: View {
    @Bindable var viewModel: ItemListViewModel
    var syncViewModel: SyncViewModel
    @Binding var selectedTab: RootView.RootTab

    @State private var showingAddItem = false
    @State private var showingImportExport = false
    @State private var showingSync = false

    var body: some View {
        NavigationStack {
            List {
                if !viewModel.items.isEmpty {
                    Section {
                        summaryAndSearchHeader
                    }
                    .listRowBackground(Color.clear)
                    .listSectionSeparator(.hidden)
                }

                if let progress = viewModel.refreshProgress, viewModel.isRefreshingCatalog {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            Text(progress.currentTitle.map { "Comprobando: \($0)" } ?? "Comprobando \(progress.completed) de \(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(viewModel.categorySections) { section in
                    Section {
                        ForEach(section.items) { item in
                            NavigationLink(value: item.id) {
                                ItemRowView(item: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { viewModel.delete(section.items[index]) }
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .font(.system(.title3, design: .serif, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(section.items.count, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.vertical, 8)
                    }
                }

                if viewModel.filteredItems.isEmpty {
                    emptyState
                }
            }
            .listStyle(.insetGrouped)
            // The floating tab bar otherwise covers the last section's bottom
            // rows — this is scroll-content margin, not a tab-bar offset, so
            // it never fights the tab bar's own layout.
            .contentMargins(.bottom, 90, for: .scrollContent)
            .navigationTitle("Mis precios")
            .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar en el catálogo")
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
                    .accessibilityIdentifier("add-item-button")
                    .accessibilityLabel("Añadir artículo")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if viewModel.isRefreshingCatalog {
                            Button("Cancelar actualización", systemImage: "xmark", role: .destructive) {
                                viewModel.cancelRefreshCatalog()
                            }
                        } else {
                            Button("Actualizar precios", systemImage: "arrow.clockwise") {
                                viewModel.startRefreshCatalog()
                            }
                        }
                        Button("Enlaces compartidos", systemImage: "tray.and.arrow.down") {
                            selectedTab = .inbox
                        }
                        Button("Sincronizar con iCloud", systemImage: "icloud") {
                            showingSync = true
                        }
                        Button("Importar / exportar JSON", systemImage: "square.and.arrow.up.on.square") {
                            showingImportExport = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Opciones del catálogo")
                }
            }
            .sheet(isPresented: $showingAddItem) {
                AddItemView(onAdded: { await viewModel.load() })
            }
            .sheet(isPresented: $showingImportExport) {
                ImportExportView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingSync) {
                NavigationStack {
                    SyncView(viewModel: syncViewModel)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cerrar") { showingSync = false }
                            }
                        }
                }
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
            .refreshable { await viewModel.load() }
        }
    }

    private var summaryAndSearchHeader: some View {
        let summary = viewModel.summary
        return VStack(alignment: .leading, spacing: 10) {
            if summary.total > 0 {
                Text("Observar. Comparar. Decidir.")
                    .font(.system(.title2, design: .serif, weight: .medium))
                    .padding(.horizontal, Self.headerHorizontalInset)
                Text(summaryText(summary))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.headerHorizontalInset)
            }
            filterChips
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        // The row must span the full width; the text re-applies the list's own
        // inset so it still aligns with the rows, while the chip strip can
        // scroll past both screen edges instead of sitting in an inset box.
        .listRowInsets(EdgeInsets())
    }

    /// Matches the inset-grouped list's horizontal margin so edge-to-edge rows
    /// keep their text aligned with the rest of the list.
    private static let headerHorizontalInset: CGFloat = 20

    private func summaryText(_ summary: (total: Int, discounted: Int, unchecked: Int)) -> String {
        var parts = ["\(summary.total) producto\(summary.total == 1 ? "" : "s")"]
        if summary.discounted > 0 { parts.append("\(summary.discounted) por debajo del precio inicial") }
        if summary.unchecked > 0 { parts.append("\(summary.unchecked) sin comprobar") }
        return parts.joined(separator: " · ")
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ItemStatusFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.displayName,
                        isSelected: viewModel.statusFilter == filter,
                        showsCheckmark: true
                    ) {
                        viewModel.statusFilter = filter
                    }
                }
                Menu {
                    Picker("Categoría", selection: $viewModel.categoryFilter) {
                        Label("Todas", systemImage: "square.grid.2x2")
                            .tag(ItemCategoryFilter.all)
                        ForEach(viewModel.categories, id: \.self) { category in
                            Text(category)
                                .tag(ItemCategoryFilter.category(category))
                        }
                        if viewModel.hasUncategorizedItems {
                            Label("Sin categoría", systemImage: "tag.slash")
                                .tag(ItemCategoryFilter.uncategorized)
                        }
                    }
                } label: {
                    FilterChip(
                        title: viewModel.isCategoryFilterActive ? viewModel.categoryFilter.displayName : "Categoría",
                        isSelected: viewModel.isCategoryFilterActive,
                        showsCheckmark: false,
                        showsChevron: true,
                        action: nil
                    )
                }
                .accessibilityIdentifier("category-filter-menu")
            }
            // Inset the chips themselves, not the scroll view, so the first and
            // last chip align with the list rows yet can scroll to the edge.
            .padding(.horizontal, Self.headerHorizontalInset)
        }
        // Without this the scroll view inherits the list row's content margins
        // and the strip looks framed, stopping short of the screen edges.
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollClipDisabled()
        .accessibilityIdentifier("catalog-filters")
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                viewModel.items.isEmpty ? "Sin productos todavía" : "Sin resultados",
                systemImage: viewModel.items.isEmpty ? "tag" : "line.3.horizontal.decrease.circle",
                description: Text(
                    viewModel.items.isEmpty
                        ? "Pega el enlace de una tienda y PriceTracker guardará su precio. Organiza tu catálogo y compara cada precio con el que guardaste."
                        : "Cambia la búsqueda o los filtros."
                )
            )
            if viewModel.items.isEmpty {
                VStack(spacing: 10) {
                    Button {
                        showingAddItem = true
                    } label: {
                        Label("Añadir URL", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)

                    Button {
                        showingImportExport = true
                    } label: {
                        Label("Importar JSON", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var showsCheckmark: Bool = true
    var showsChevron: Bool = false
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if isSelected && showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
            }
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
        .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
        .clipShape(Capsule())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
