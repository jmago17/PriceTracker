import Foundation
import Observation

enum ItemStatusFilter: String, CaseIterable, Hashable, Sendable {
    case active
    case discounted
    case paused

    var displayName: String {
        switch self {
        case .active: return "Activos"
        case .discounted: return "Menos que al añadir"
        case .paused: return "Pausados"
        }
    }
}

@MainActor
@Observable
final class ItemListViewModel {
    private(set) var items: [Item] = []
    private(set) var histories: [String: [PriceObservation]] = [:]
    private(set) var historyErrors: [String: String] = [:]
    var searchText: String = ""
    var categoryFilter: ItemCategoryFilter = .all
    var statusFilter: ItemStatusFilter = .active
    private(set) var isRefreshingCatalog = false
    private(set) var refreshProgress: RefreshProgress?
    var lastErrorMessage: String?
    var lastRefreshMessage: String?
    /// Informational result of a single-item server check (e.g. "deferred").
    var refreshNotice: String?
    /// Items whose Apple Intelligence summary is being generated right now.
    private(set) var summarizingIDs: Set<UUID> = []
    private(set) var summaryErrors: [UUID: String] = [:]

    private let environment: AppEnvironment
    private var refreshTask: Task<Void, Never>?

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    /// Independent of the active category, search and paused-items filter.
    var lastSuccessfulPriceCheck: Date? {
        CatalogPriceCheck.latestSuccess(in: items)
    }

    var categories: [String] {
        ItemFilterEngine.categoryNames(in: items)
    }

    var hasUncategorizedItems: Bool {
        items.contains { ItemFilterEngine.normalizedCategory($0.category) == nil }
    }

    var isCategoryFilterActive: Bool {
        categoryFilter != .all
    }

    /// Catalog overview excluding paused items, independent of search/category.
    /// The reduction count compares recorded prices with their original baseline.
    var summary: (total: Int, discounted: Int, unchecked: Int) {
        let visible = items.filter { $0.status != .archived }
        return (
            total: visible.count,
            discounted: visible.filter(Self.isDiscounted).count,
            unchecked: visible.filter { $0.lastCheckedAt == nil }.count
        )
    }

    static func isDiscounted(_ item: Item) -> Bool {
        item.reductionSinceAddedCents != nil
    }

    var filteredItems: [Item] {
        var result = ItemFilterEngine.filter(items, by: categoryFilter)
        switch statusFilter {
        case .active:
            result = result.filter { $0.status == .active || $0.status == .stale }
        case .discounted:
            result = result.filter { $0.status != .archived && Self.isDiscounted($0) }
        case .paused:
            result = result.filter { $0.status == .archived }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var categorySections: [ItemFilterEngine.CategorySection] {
        ItemFilterEngine.sections(in: filteredItems)
    }

    func load() async {
        do {
            items = try await environment.itemStore.loadAll()
            reconcileCategoryFilter()
            // A history-only CloudKit change need not modify the Item payload.
            // Refresh only histories already requested by an open detail.
            for item in items where histories[item.identityKey] != nil || historyErrors[item.identityKey] != nil {
                await loadHistory(for: item, fetchRemote: false)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Items in catalog order for a set of ids (multi-selection sharing).
    func items(withIDs ids: Set<UUID>) -> [Item] {
        filteredItems.filter { ids.contains($0.id) }
    }

    /// Called after any add path. The summary is generated in the background
    /// so saving never waits for the model.
    func didAdd(_ item: Item, pageText: String?) async {
        await load()
        guard pageText?.trimmedNonEmpty != nil else { return }
        Task { await summarize(item, pageText: pageText) }
    }

    /// "Generar resumen" in the ficha: reads the page again and summarizes it.
    func generateSummary(for item: Item) {
        Task { await summarize(item, pageText: nil) }
    }

    var canSummarize: Bool { ProductInsightGenerator.isAvailable }

    private func summarize(_ item: Item, pageText: String?) async {
        guard !AppGroup.isDemo, !summarizingIDs.contains(item.id) else { return }
        summarizingIDs.insert(item.id)
        summaryErrors[item.id] = nil
        defer { summarizingIDs.remove(item.id) }
        do {
            let enricher = ItemEnricher(itemStore: environment.itemStore, connectors: environment.connectors)
            _ = try await enricher.enrich(item, pageText: pageText)
            await load()
        } catch {
            // Automatic runs after adding stay silent; only an explicit request
            // shows why no summary was produced.
            if pageText == nil {
                summaryErrors[item.id] = error.localizedDescription
            }
        }
    }

    func delete(_ item: Item) {
        Task {
            do {
                try await environment.itemStore.delete(id: item.id)
                await load()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshSingle(_ item: Item) async {
        lastErrorMessage = nil
        refreshNotice = nil
        if let remote = environment.remoteStore {
            do {
                let result = try await remote.refresh(id: item.id)
                if result.deferred {
                    refreshNotice = "Este artículo no se puede comprobar al momento: lo comprueba la rutina de las 08:00."
                        + (result.why?.trimmedNonEmpty.map { " (\($0))" } ?? "")
                }
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            await load()
            await loadHistory(for: item)
            return
        }
        let result = await environment.refreshCoordinator.refreshResult(id: item.id)
        await load()
        await loadHistory(for: item)
        if let error = result.error { lastErrorMessage = error }
    }

    /// Opening a ficha asks the server for the history first (and caches it);
    /// without network the cached copy is shown.
    func loadHistory(for item: Item, fetchRemote: Bool = true) async {
        if fetchRemote, let remote = environment.remoteStore, remote.isConfigured {
            try? await remote.refreshHistory(for: item)
        }
        do {
            histories[item.identityKey] = try await environment.itemStore.observations(for: item.identityKey)
            historyErrors[item.identityKey] = nil
        } catch {
            historyErrors[item.identityKey] = error.localizedDescription
        }
    }

    func setPriority(_ priority: ItemPriority, for item: Item) async {
        do {
            guard let current = try await environment.itemStore.item(id: item.id) else { return }
            var updated = current
            updated.priority = priority
            updated.updatedAt = Date()
            _ = try await environment.itemStore.commitRefresh(updated, expected: current, observation: nil)
            await load()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func useCurrentPriceAsInitial(_ item: Item) async {
        do {
            guard let current = try await environment.itemStore.item(id: item.id) else { return }
            var updated = current
            guard updated.useCurrentPriceAsInitial() else { return }
            _ = try await environment.itemStore.commitRefresh(updated, expected: current, observation: nil)
            await load()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func save(_ item: Item) {
        Task {
            do {
                try await environment.itemStore.upsert(item)
                await load()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// "Pausar"/"Reanudar" in the ficha's bottom bar — reuses `.archived`, which
    /// already excludes an item from refresh batches (RefreshCoordinator) and
    /// from the default "Activos" chip.
    func togglePause(_ item: Item) {
        var updated = item
        updated.status = item.status == .archived ? .active : .archived
        updated.updatedAt = Date()
        save(updated)
    }

    func refreshCategory(_ category: String?) {
        if environment.isRemote {
            startRefreshCatalog()
            return
        }
        Task {
            do {
                let summary = try await environment.refreshCoordinator.refreshCategory(category)
                await load()
                lastRefreshMessage = summary.completionMessage
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Manual "refresh everything" from the UI: a cancelable, progress-reporting
    /// task that never blocks the main thread — see Refresh/RefreshCoordinator.swift.
    func startRefreshCatalog() {
        guard refreshTask == nil else { return }
        isRefreshingCatalog = true
        refreshProgress = nil
        lastErrorMessage = nil
        lastRefreshMessage = nil
        if let remote = environment.remoteStore {
            // The server does the price checks; "refresh" pulls its latest state.
            refreshTask = Task {
                do { try await remote.sync() }
                catch is CancellationError {}
                catch { lastErrorMessage = error.localizedDescription }
                await load()
                isRefreshingCatalog = false
                refreshTask = nil
            }
            return
        }
        refreshTask = Task {
            var completionMessage: String?
            do {
                let summary = try await environment.refreshCoordinator.refreshCatalog { progress in
                    self.refreshProgress = progress
                }
                completionMessage = summary.completionMessage
            } catch is CancellationError {
                // user-initiated cancel — not an error worth surfacing
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            await load()
            isRefreshingCatalog = false
            refreshTask = nil
            lastRefreshMessage = completionMessage
        }
    }

    /// Pull-to-refresh uses the same network operation and awaits its completion.
    func refreshCatalog() async {
        startRefreshCatalog()
        await refreshTask?.value
    }

    func cancelRefreshCatalog() {
        refreshTask?.cancel()
    }

    private func reconcileCategoryFilter() {
        switch categoryFilter {
        case .all:
            break
        case .category(let category) where !categories.contains(category):
            categoryFilter = .all
        case .uncategorized where !hasUncategorizedItems:
            categoryFilter = .all
        default:
            break
        }
    }
}


#if DEBUG
extension ItemListViewModel {
    func loadDemo() async {
        if ProcessInfo.processInfo.arguments.contains("--demo-history") {
            let old = Date().addingTimeInterval(-4 * 86400)
            let item = Item(store: .appStore, storeItemID: "demo-history-\(UUID().uuidString)",
                canonicalURL: URL(string: "https://example.com/history")!, title: "Precio estable (demo)",
                priceCurrentCents: 1299, priceAtAddCents: 1299, priceLowCents: 1299,
                lastCheckedAt: old, lastSuccessAt: old)
            do {
                try await environment.itemStore.save([item])
                if !ProcessInfo.processInfo.arguments.contains("--demo-history-empty") {
                    let observation = PriceObservation(itemID: item.id, checkedAt: old, priceCents: 1299, currency: "EUR", isOnSale: false)
                    try await environment.itemStore.upsert(item, observation: observation)
                }
                await load()
            } catch { lastErrorMessage = error.localizedDescription }
            return
        }
        struct Example {
            let title: String
            let category: String?
            let priceCurrentCents: Int
            let priceAtAddCents: Int
            let imageURL: URL?
            let summary: String?
            let size: String?
            let color: String?
        }
        let examples: [Example] = [
            Example(title: "Things — organiza tus ideas", category: "Productividad", priceCurrentCents: 1499, priceAtAddCents: 2499, imageURL: nil, summary: nil, size: nil, color: nil),
            Example(title: "Agenda de papel", category: "Productividad", priceCurrentCents: 1890, priceAtAddCents: 1890, imageURL: URL(string: "https://example.com/img/agenda.jpg"), summary: "Agenda anual de tapa dura con gomas elásticas y separadores mensuales.", size: nil, color: "Burdeos"),
            Example(title: "El arte de observar", category: "Libros", priceCurrentCents: 899, priceAtAddCents: 1299, imageURL: URL(string: "https://example.com/img/libro.jpg"), summary: "Ensayo breve sobre atención y percepción visual, con casos prácticos.", size: nil, color: nil),
            Example(title: "Rutas y viajes", category: "Libros", priceCurrentCents: 1599, priceAtAddCents: 1599, imageURL: nil, summary: nil, size: nil, color: nil),
            Example(title: "Auriculares de estudio", category: "Tecnología", priceCurrentCents: 12900, priceAtAddCents: 15900, imageURL: URL(string: "https://example.com/img/auriculares.jpg"), summary: "Auriculares cerrados de monitorización, cable desmontable de 3 m.", size: nil, color: "Negro"),
            Example(title: "Lámpara de lectura", category: nil, priceCurrentCents: 3900, priceAtAddCents: 3900, imageURL: nil, summary: nil, size: nil, color: nil),
            Example(title: "Camiseta básica", category: "Ropa", priceCurrentCents: 1299, priceAtAddCents: 1299, imageURL: nil, summary: "Camiseta de algodón orgánico, corte regular.", size: "M", color: "Verde oliva")
        ]
        items = examples.enumerated().map { index, example in
            Item(store: .generic, storeItemID: "demo-\(index)", canonicalURL: URL(string: "https://example.com/\(index)")!, title: example.title, subtitle: "Catálogo de demostración", imageURL: example.imageURL, category: example.category, priceCurrentCents: example.priceCurrentCents, priceAtAddCents: example.priceAtAddCents, priceLowCents: example.priceCurrentCents, lastCheckedAt: Date(), lastSuccessAt: Date(), summary: example.summary, size: example.size, color: example.color)
        }
        do { try await environment.itemStore.save(items) }
        catch { lastErrorMessage = error.localizedDescription }
    }
}
#else
extension ItemListViewModel {
    func loadDemo() async {}
}
#endif
