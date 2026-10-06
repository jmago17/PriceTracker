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
            return items.filter { normalizedCategory($0.category) == normalizedCategory(category) }
        case .uncategorized:
            return items.filter { normalizedCategory($0.category) == nil }
        }
    }

    static func categoryNames(in items: [Item]) -> [String] {
        Set(items.compactMap { normalizedCategory($0.category) }).sorted {
            let comparison = $0.localizedCaseInsensitiveCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }

    static func normalizedCategory(_ category: String?) -> String? {
        guard let name = category?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    struct CategorySection: Identifiable {
        let category: String?
        let items: [Item]
        var id: ItemCategoryFilter { category.map(ItemCategoryFilter.category) ?? .uncategorized }
        var title: String { category ?? "Sin categoría" }
    }

    /// Groups an already filtered/sorted sequence; preserves order within each category.
    /// Unknown category names remain visible, and missing/blank names share the last section.
    static func sections(in items: [Item]) -> [CategorySection] {
        let groups = Dictionary(grouping: items) { normalizedCategory($0.category) }
        let names = categoryNames(in: items)
        var sections = names.map { CategorySection(category: $0, items: groups[$0] ?? []) }
        if let unclassified = groups[nil] {
            sections.append(CategorySection(category: nil, items: unclassified))
        }
        return sections
    }

}
