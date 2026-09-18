import AppIntents
import CoreSpotlight
import Foundation

/// The entity behind the "Buscar Artículos" Shortcuts action (via `ItemQuery`,
/// an `EntityPropertyQuery`) and the parameter type of `RefreshItemIntent`.
struct ItemEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Artículo")
    }

    static let defaultQuery = ItemQuery()

    let id: UUID

    @Property(title: "Título")
    var title: String

    @Property(title: "Tienda")
    var store: Store

    @Property(title: "Categoría")
    var category: String

    @Property(title: "Estado")
    var status: ItemStatus

    @Property(title: "Precio actual (céntimos)")
    var priceCurrentCents: Int

    @Property(title: "Divisa")
    var currency: String

    @Property(title: "Última comprobación")
    var lastCheckedAt: Date?

    init(item: Item) {
        id = item.id
        title = item.title
        store = item.store
        category = item.category ?? ""
        status = item.status
        priceCurrentCents = item.priceCurrentCents ?? 0
        currency = item.currency
        lastCheckedAt = item.lastCheckedAt
    }

    var displayRepresentation: DisplayRepresentation {
        let priceText = priceCurrentCents > 0 ? MoneyFormatter.string(cents: priceCurrentCents, currency: currency) : "sin precio"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(store.displayName) · \(priceText)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = priceCurrentCents > 0
            ? "\(store.displayName) · \(MoneyFormatter.string(cents: priceCurrentCents, currency: currency))"
            : store.displayName
        attributes.keywords = [title, store.displayName, category].filter { !$0.isEmpty }
        return attributes
    }
}
