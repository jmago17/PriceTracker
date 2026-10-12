import SwiftUI

/// iPhone defaults to an inset-grouped list, with an optional gray masonry
/// mural. iPad uses the same cards and controls. All presentations share
/// selection, sharing, sheets and navigation.
struct CatalogView: View {
    @Bindable var viewModel: ItemListViewModel
    var syncViewModel: SyncViewModel
    @Binding var selectedTab: RootView.RootTab

    @AppStorage("compactCatalogMuralEnabled") private var compactCatalogMuralEnabled = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var regularColumnWidth: CGFloat = 240
    @ScaledMetric(relativeTo: .body) private var compactColumnWidth: CGFloat = 156
    @State private var compactSearchRequest = 0

    @State private var showingAddItem = false
    @State private var showingImportExport = false
    @State private var showingSync = false
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @FocusState private var muralSearchFocused: Bool

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var usesMural: Bool { UIDevice.current.userInterfaceIdiom == .pad || isRegular || compactCatalogMuralEnabled }

    var body: some View {
        NavigationStack {
            Group {
                if usesMural {
                    mural
                } else {
                    compactList
                }
            }
            .navigationTitle("Mis precios")
            .navigationDestination(for: UUID.self) { id in
                if let item = viewModel.items.first(where: { $0.id == id }) {
                    ItemDetailView(item: item, viewModel: viewModel)
                }
            }
            .toolbar { toolbarContent }
            .toolbar(isSelecting && !isRegular ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    SelectionShareBar(items: viewModel.items(withIDs: selection))
                } else if usesMural && !muralSearchFocused {
                    compactMuralBottomControls
                        .frame(maxWidth: 600)
                }
            }
            .sheet(isPresented: $showingAddItem) {
                AddItemView(onAdded: { item, pageText in
                    await viewModel.didAdd(item, pageText: pageText)
                })
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
            .onChange(of: viewModel.filteredItems.map(\.id)) { _, visible in
                // Never share something the user can no longer see.
                selection.formIntersection(visible)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "Ninguno" : "Seleccionar todo") {
                    if allVisibleSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(viewModel.filteredItems.map(\.id))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Listo") { endSelection() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("end-selection-button")
            }
        } else {
            if !usesMural {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("add-item-button")
                    .accessibilityLabel("Añadir artículo")
                }
            } else if !viewModel.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Seleccionar") { startSelection() }
                        .accessibilityIdentifier("start-selection-button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !usesMural && !viewModel.items.isEmpty {
                        Button("Seleccionar", systemImage: "checkmark.circle") { startSelection() }
                    }
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
        ToolbarItemGroup(placement: .keyboard) {
            if usesMural {
                Spacer()
                Button("Listo") { muralSearchFocused = false }
                    .accessibilityIdentifier("dismiss-mural-keyboard-button")
            }
        }
    }

    private var allVisibleSelected: Bool {
        let visible = Set(viewModel.filteredItems.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    private func endSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private func startSelection() {
        muralSearchFocused = false
        isSelecting = true
    }

    private func beginSelection(with item: Item) {
        selection = [item.id]
        startSelection()
    }

    // MARK: iPhone list

    private var compactList: some View {
        // No `selection:` on this List: merely declaring that parameter — even
        // bound to a throwaway value — makes a plain tap toggle the row instead
        // of pushing its NavigationLink. Multi-select below mirrors the iPad
        // mural instead: a custom indicator + a Button that toggles `selection`
        // while isSelecting, a plain NavigationLink otherwise.
        List {
            Section {
                lastPriceCheckLine
                if !viewModel.items.isEmpty && !isSelecting {
                    summaryAndSearchHeader
                }
            }
            .listRowBackground(Color.clear)
            .listSectionSeparator(.hidden)

            refreshProgressSection

            ForEach(viewModel.categorySections) { section in
                Section {
                    ForEach(section.items) { item in
                        compactRow(item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0))
                    }
                    .onDelete { offsets in
                        guard !isSelecting else { return }
                        for index in offsets { viewModel.delete(section.items[index]) }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(CategoryLabel.displayName(section.category, among: viewModel.categories))
                            .accessibilityLabel(section.title)
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
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        // The floating tab bar otherwise covers the last section's bottom
        // rows — this is scroll-content margin, not a tab-bar offset, so
        // it never fights the tab bar's own layout.
        .contentMargins(.bottom, 90, for: .scrollContent)
        .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar en el catálogo")
    }

    @ViewBuilder
    private func compactRow(_ item: Item) -> some View {
        let card = CompactMuralCardView(
            item: item,
            categoryLabel: CategoryLabel.displayName(item.category, among: viewModel.categories),
            isSelecting: isSelecting,
            isSelected: selection.contains(item.id),
            isSummarizing: viewModel.summarizingIDs.contains(item.id),
            imageOnTrailingSide: UIDevice.current.userInterfaceIdiom == .phone
        )
        if isSelecting {
            Button {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
            .accessibilityIdentifier("item-row")
        } else {
            NavigationLink(value: item.id) {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("item-row")
            .contextMenu {
                ItemContextMenu(item: item, viewModel: viewModel) {
                    beginSelection(with: item)
                }
            }
        }
    }

    @ViewBuilder
    private var refreshProgressSection: some View {
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

    private var lastPriceCheckLine: some View {
        Group {
            if let date = viewModel.lastSuccessfulPriceCheck {
                Text("Último precio comprobado: \(CatalogPriceCheck.formatted(date, locale: locale, calendar: calendar, timeZone: timeZone))")
            } else {
                Text("Último precio comprobado: sin datos")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("catalog-last-price-check")
        .accessibilityHint("Comprobación correcta más reciente de un artículo; no indica que se haya actualizado todo el catálogo.")
    }

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
                            Text(CategoryLabel.displayName(category, among: viewModel.categories))
                                .accessibilityLabel(category)
                                .help(category)
                                .tag(ItemCategoryFilter.category(category))
                        }
                        if viewModel.hasUncategorizedItems {
                            Label("Sin categoría", systemImage: "tag.slash")
                                .tag(ItemCategoryFilter.uncategorized)
                        }
                    }
                } label: {
                    FilterChip(
                        title: viewModel.isCategoryFilterActive ? CategoryLabel.displayName(viewModel.categoryFilter.displayName, among: viewModel.categories) : "Categoría",
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

    // MARK: Adaptive mural

    private var mural: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: isRegular ? 18 : 14) {
                    muralSearchField
                        .id("mural-search-header")
                    lastPriceCheckLine
                    muralChips

                    if let progress = viewModel.refreshProgress, viewModel.isRefreshingCatalog {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            Text(progress.currentTitle.map { "Comprobando: \($0)" } ?? "Comprobando \(progress.completed) de \(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                    }

                    if viewModel.filteredItems.isEmpty {
                        emptyState
                    } else if isRegular {
                        MasonryLayout(minColumnWidth: regularColumnWidth, spacing: 22, maximumColumns: dynamicTypeSize.isAccessibilitySize ? 1 : nil, initialColumnOffset: dynamicTypeSize.isAccessibilitySize ? 0 : 52) {
                            ForEach(viewModel.filteredItems) { item in
                                muralCard(item)
                            }
                        }
                        .padding(.top, 6)
                    } else {
                        // Two columns at ordinary phone widths; one below 326 pt
                        // of content width or at accessibility sizes. The second
                        // column starts lower; measured content determines heights.
                        MasonryLayout(
                            minColumnWidth: compactColumnWidth,
                            spacing: 14,
                            maximumColumns: dynamicTypeSize.isAccessibilitySize ? 1 : 2,
                            initialColumnOffset: 52
                        ) {
                            ForEach(viewModel.filteredItems) { item in
                                muralCard(item)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, isRegular ? 40 : 16)
                .padding(.top, 8)
                .padding(.bottom, isRegular ? 40 : 24)
            }
            .accessibilityIdentifier(isRegular ? "catalog-mural-regular" : "catalog-mural-compact")
            .scrollDismissesKeyboard(.interactively)
            // Scroll-content margin also clears iPhone's floating tab bar.
            .contentMargins(.bottom, isRegular ? 0 : 80, for: .scrollContent)
            .toolbar(removing: .title)
            .background(Color(.systemGroupedBackground))
            .onChange(of: compactSearchRequest) { _, _ in
                // Scroll and focus even when invoked from the end of the mural.
                // No animated jump, including when Reduce Motion is enabled.
                scrollProxy.scrollTo("mural-search-header", anchor: .top)
                muralSearchFocused = true
            }
        }
    }

    @ViewBuilder
    private func muralCard(_ item: Item) -> some View {
        let card = CompactMuralCardView(
            item: item,
            categoryLabel: CategoryLabel.displayName(item.category, among: viewModel.categories),
            isSelecting: isSelecting,
            isSelected: selection.contains(item.id),
            isSummarizing: viewModel.summarizingIDs.contains(item.id)
        )
        if isSelecting {
            Button {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("item-card")
        } else {
            NavigationLink(value: item.id) {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("item-card")
            .contextMenu {
                ItemContextMenu(item: item, viewModel: viewModel) {
                    beginSelection(with: item)
                }
            }
        }
    }

    private var muralSearchField: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("Busca en tus precios…", text: $viewModel.searchText)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($muralSearchFocused)
                .onSubmit { muralSearchFocused = false }
                .accessibilityLabel("Buscar en el catálogo")
                .accessibilityIdentifier("mural-search-field")
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    muralSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private var muralChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                MuralChip(title: "Todo", count: categoryCount(nil), isSelected: viewModel.categoryFilter == .all) {
                    viewModel.categoryFilter = .all
                }
                ForEach(viewModel.categories, id: \.self) { category in
                    MuralChip(
                        title: CategoryLabel.displayName(category, among: viewModel.categories),
                        count: categoryCount(category),
                        isSelected: viewModel.categoryFilter == .category(category)
                    ) {
                        viewModel.categoryFilter = .category(category)
                    }
                    .accessibilityLabel(category)
                    .help(category)
                }
                if viewModel.hasUncategorizedItems {
                    MuralChip(
                        title: "Sin categoría",
                        count: uncategorizedCount,
                        isSelected: viewModel.categoryFilter == .uncategorized
                    ) {
                        viewModel.categoryFilter = .uncategorized
                    }
                }
                if isRegular && !viewModel.items.isEmpty {
                    Text(summaryText(viewModel.summary))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .fixedSize()
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("catalog-filters")
    }

    private var unpausedItems: [Item] {
        viewModel.items.filter { $0.status != .archived }
    }

    private func categoryCount(_ category: String?) -> Int {
        guard let category else { return unpausedItems.count }
        return unpausedItems.filter { ItemFilterEngine.normalizedCategory($0.category) == category }.count
    }

    private var uncategorizedCount: Int {
        unpausedItems.filter { ItemFilterEngine.normalizedCategory($0.category) == nil }.count
    }

    /// Ordered circular actions live in a safe-area inset, never over the last
    /// card or tab bar. Search returns to and focuses the discreet header.
    private var compactMuralBottomControls: some View {
        HStack(spacing: 12) {
            Button { compactSearchRequest += 1 } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Buscar en el catálogo")
            .accessibilityIdentifier("mural-search-button")

            Spacer(minLength: 0)
            Button {
                if viewModel.isRefreshingCatalog {
                    viewModel.cancelRefreshCatalog()
                } else {
                    viewModel.startRefreshCatalog()
                }
            } label: {
                Image(systemName: viewModel.isRefreshingCatalog ? "xmark" : "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(viewModel.isRefreshingCatalog ? "Cancelar actualización" : "Actualizar precios")
            .accessibilityIdentifier("mural-refresh-button")

            Spacer(minLength: 0)

            Menu {
                Picker("Estado", selection: $viewModel.statusFilter) {
                    ForEach(ItemStatusFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .overlay(alignment: .topTrailing) {
                        if viewModel.statusFilter != .active {
                            Circle().fill(Color.primary).frame(width: 6, height: 6).padding(8)
                        }
                    }
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Filtrar por estado")
            .accessibilityValue(viewModel.statusFilter.displayName)
            .accessibilityIdentifier("mural-status-filter-menu")

            Spacer(minLength: 0)

            Button { showingAddItem = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 48, height: 48)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Añadir artículo")
            .accessibilityIdentifier("add-item-button")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Empty state

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
    }
}

private extension ItemStatusFilter {
    var shortName: String {
        switch self {
        case .active: return "Activos"
        case .discounted: return "Con bajada"
        case .paused: return "Pausados"
        }
    }
}

private struct MuralChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color(.systemBackground).opacity(0.7) : Color.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
            .background(isSelected ? Color.primary : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
