import Foundation
import Observation

@MainActor
@Observable
final class ItemListViewModel {
    private(set) var items: [Item] = []
    var searchText: String = ""
    var categoryFilter: ItemCategoryFilter = .all
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

    var filteredItems: [Item] {
        var result = ItemFilterEngine.filter(items, by: categoryFilter)
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Items grouped by category for the sectioned list, each section sorted by
    /// title, with uncategorized items last.
    var itemsByCategory: [(category: String?, items: [Item])] {
        let grouped = Dictionary(grouping: filteredItems, by: \.category)
        return grouped
            .sorted { lhs, rhs in
                switch (lhs.key, rhs.key) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
            }
            .map { (category: $0.key, items: $0.value) }
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
