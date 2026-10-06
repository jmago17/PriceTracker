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
    var searchText: String = ""
    var categoryFilter: ItemCategoryFilter = .all
    var statusFilter: ItemStatusFilter = .active
    private(set) var isRefreshingCatalog = false
    private(set) var refreshProgress: RefreshProgress?
    var lastErrorMessage: String?

    private let environment: AppEnvironment
    private var refreshTask: Task<Void, Never>?

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
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
        } catch {
            lastErrorMessage = error.localizedDescription
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

    func refreshSingle(_ item: Item) {
        Task {
            do {
                _ = try await environment.refreshCoordinator.refreshItem(id: item.id)
                await load()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
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
        Task {
            do {
                _ = try await environment.refreshCoordinator.refreshCategory(category)
                await load()
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
        refreshTask = Task {
            do {
                _ = try await environment.refreshCoordinator.refreshCatalog { progress in
                    self.refreshProgress = progress
                }
            } catch is CancellationError {
                // user-initiated cancel — not an error worth surfacing
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            isRefreshingCatalog = false
            refreshTask = nil
            await load()
        }
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
        let examples: [(String, String?, Int, Int)] = [
            ("Things — organiza tus ideas", "Productividad", 1499, 2499),
            ("Agenda de papel", "Productividad", 1890, 1890),
            ("El arte de observar", "Libros", 899, 1299),
            ("Rutas y viajes", "Libros", 1599, 1599),
            ("Auriculares de estudio", "Tecnología", 12900, 15900),
            ("Lámpara de lectura", nil, 3900, 3900)
        ]
        items = examples.enumerated().map { index, example in
            Item(store: .generic, storeItemID: "demo-\(index)", canonicalURL: URL(string: "https://example.com/\(index)")!, title: example.0, subtitle: "Catálogo de demostración", category: example.1, priceCurrentCents: example.2, priceAtAddCents: example.3, priceLowCents: example.2, lastCheckedAt: Date())
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
