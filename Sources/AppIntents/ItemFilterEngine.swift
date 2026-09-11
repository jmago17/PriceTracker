import Foundation

/// Pure filter/sort/limit engine, deliberately independent of the AppIntents
/// framework so it can be unit tested directly (see
/// Tests/PriceTrackerTests/ItemFilterEngineTests.swift) without needing a host
/// app or Shortcuts runtime. `ItemQuery` (AppIntents/ItemQuery.swift) is a thin
/// adapter on top of this.
enum FilterMode: Sendable {
    case and
    case or
}

enum ItemSortKey: Sendable {
    case title
    case lastCheckedAt
    case priceCurrent
}

enum ItemCategoryFilter: Hashable, Sendable {
    case all
    case category(String)
    case uncategorized

    var displayName: String {
        switch self {
        case .all: return "Todas"
        case .category(let name): return name
        case .uncategorized: return "Sin categoría"
        }
    }
}

enum ItemFilterEngine {
    static func filter(_ items: [Item], predicates: [@Sendable (Item) -> Bool], mode: FilterMode) -> [Item] {
        guard !predicates.isEmpty else { return items }
        switch mode {
        case .and:
            return items.filter { item in predicates.allSatisfy { $0(item) } }
        case .or:
            return items.filter { item in predicates.contains { $0(item) } }
        }
    }

    static func sort(_ items: [Item], by key: ItemSortKey, ascending: Bool) -> [Item] {
        let sorted: [Item]
        switch key {
        case .title:
            sorted = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastCheckedAt:
            sorted = items.sorted { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }
        case .priceCurrent:
            sorted = items.sorted { ($0.priceCurrentCents ?? .max) < ($1.priceCurrentCents ?? .max) }
        }
        return ascending ? sorted : sorted.reversed()
    }

    static func limit(_ items: [Item], to limit: Int?) -> [Item] {
        guard let limit else { return items }
        return Array(items.prefix(limit))
    }

    static func filter(_ items: [Item], by categoryFilter: ItemCategoryFilter) -> [Item] {
        switch categoryFilter {
        case .all:
            return items
        case .category(let category):
            return items.filter { $0.category == category }
        case .uncategorized:
            return items.filter { $0.category == nil }
        }
    }

    static func categoryNames(in items: [Item]) -> [String] {
        Set(items.compactMap(\.category)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
