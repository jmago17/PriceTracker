import AppIntents
import Foundation

/// Backs the "Buscar Artículos" Shortcuts action. This is the `FindItems` half
/// of the FindItems + "Repeat with each" RefreshItem pattern from
/// /tmp/josu_pushback2.md — verified against the real iOS 27 AppIntents
/// framework to be the pattern `EntityPropertyQuery` was built for (filter by
/// store/category/status/staleness, sort by last-checked, cap with `limit:`).
///
/// The actual filter/sort/limit logic lives in `ItemFilterEngine` so it can be
/// unit tested without the AppIntents runtime; this type is a thin adapter.
struct ItemQuery: EntityPropertyQuery {
    typealias ComparatorMappingType = @Sendable (Item) -> Bool

    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\ItemEntity.$store) {
            EqualToComparator { (value: Store) -> ComparatorMappingType in
                { item in item.store == value }
            }
        }
        Property(\ItemEntity.$category) {
            EqualToComparator { (value: String) -> ComparatorMappingType in
                { item in (item.category ?? "") == value }
            }
        }
        Property(\ItemEntity.$status) {
            EqualToComparator { (value: ItemStatus) -> ComparatorMappingType in
                { item in item.status == value }
            }
        }
        Property(\ItemEntity.$lastCheckedAt) {
            LessThanComparator { (value: Date) -> ComparatorMappingType in
                { item in (item.lastCheckedAt ?? .distantPast) < value }
            }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\ItemEntity.$title)
        SortableBy(\ItemEntity.$lastCheckedAt)
        SortableBy(\ItemEntity.$priceCurrentCents)
    }

    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ItemEntity] {
        let items = try await AppEnvironment.shared.itemStore.loadAll()
        return items.filter { identifiers.contains($0.id) }.map(ItemEntity.init(item:))
    }

    func entities(
        matching comparators: [@Sendable (Item) -> Bool],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<ItemEntity>],
        limit: Int?
    ) async throws -> [ItemEntity] {
        let items = try await AppEnvironment.shared.itemStore.loadAll()
        let filterMode: FilterMode = (mode == .and) ? .and : .or
        var result = ItemFilterEngine.filter(items, predicates: comparators, mode: filterMode)

        for sort in sortedBy.reversed() {
            let ascending = sort.order == .ascending
            if sort.by == \ItemEntity.title {
                result = ItemFilterEngine.sort(result, by: .title, ascending: ascending)
            } else if sort.by == \ItemEntity.lastCheckedAt {
                result = ItemFilterEngine.sort(result, by: .lastCheckedAt, ascending: ascending)
            } else if sort.by == \ItemEntity.priceCurrentCents {
                result = ItemFilterEngine.sort(result, by: .priceCurrent, ascending: ascending)
            }
        }

        result = ItemFilterEngine.limit(result, to: limit)
        return result.map(ItemEntity.init(item:))
    }
}
