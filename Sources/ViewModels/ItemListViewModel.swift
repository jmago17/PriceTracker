import Foundation
import Observation

enum ItemStatusFilter: String, CaseIterable, Hashable, Sendable {
    case active
    case discounted
    case paused

    var displayName: String {
        switch self {
        case .active: return "Activos"
        case .discounted: return "Con bajada"
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
        items.contains { $0.category == nil }
    }

    var isCategoryFilterActive: Bool {
        categoryFilter != .all
    }

    /// "12 productos · 3 con bajada · 1 sin comprobar" — over active+stale items
    /// (excludes paused), independent of search/category, so it reads as an
    /// overview of the default "Activos" view rather than the whole catalog —
    /// otherwise a paused drop could inflate "con bajada" past what the
    /// "Bajadas de precio" section actually lists.
    var summary: (total: Int, discounted: Int, unchecked: Int) {
        let visible = items.filter { $0.status != .archived }
        return (
            total: visible.count,
            discounted: visible.filter(Self.isDiscounted).count,
            unchecked: visible.filter { $0.lastCheckedAt == nil }.count
        )
    }

    static func isDiscounted(_ item: Item) -> Bool {
        guard let current = item.priceCurrentCents, let atAdd = item.priceAtAddCents else { return false }
        return current < atAdd
    }

    var filteredItems: [Item] {
        var result = ItemFilterEngine.filter(items, by: categoryFilter)
        switch statusFilter {
        case .active:
            result = result.filter { $0.status == .active || $0.status == .stale }
        case .discounted:
            result = result.filter(Self.isDiscounted)
        case .paused:
            result = result.filter { $0.status == .archived }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// "Bajadas de precio" first, then "Siguiendo" — category is a filter now,
    /// not a section (see handoff README, structural change #2).
    var drops: [Item] { filteredItems.filter(Self.isDiscounted) }
    var rest: [Item] { filteredItems.filter { !Self.isDiscounted($0) } }

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
