import AppIntents
import CoreSpotlight
import Foundation

/// Typed find action with property filters, sorting and limits.
struct ItemQuery: EntityPropertyQuery {
    typealias ComparatorMappingType = @Sendable (Item) -> Bool

    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\ItemEntity.$title) {
            ContainsComparator { (value: String) -> ComparatorMappingType in
                { $0.title.localizedCaseInsensitiveContains(value) }
            }
        }
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

    private let store: any ItemStoring
    init() { store = AppEnvironment.shared.itemStore }
    init(store: any ItemStoring) { self.store = store }

    func entities(for identifiers: [UUID]) async throws -> [ItemEntity] {
        let items = try await store.loadAll()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }.map(ItemEntity.init(item:))
    }

    func entities(
        matching comparators: [@Sendable (Item) -> Bool],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<ItemEntity>],
        limit: Int?
    ) async throws -> [ItemEntity] {
        let items = try await store.loadAll()
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


extension ItemQuery {
    func suggestedEntities() async throws -> [ItemEntity] {
        let items = try await store.loadAll()
        return items
            .filter { $0.status != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(10)
            .map(ItemEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [ItemEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try await store.loadAll()
        guard !needle.isEmpty else {
            return try await suggestedEntities()
        }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(needle)
                || item.subtitle?.localizedCaseInsensitiveContains(needle) == true
                || item.category?.localizedCaseInsensitiveContains(needle) == true
                || item.store.displayName.localizedCaseInsensitiveContains(needle)
        }.map(ItemEntity.init(item:))
    }
}


@available(iOS 27.0, *)
extension ItemQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [UUID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await entities(for: identifiers)
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let items = try await store.loadAll()
        let index = CSSearchableIndex.default()
        try await index.deleteAppEntities(ofType: ItemEntity.self)
        try await index.indexAppEntities(items.map(ItemEntity.init(item:)))
    }
}
