import AppIntents
import Foundation

/// The entity behind the "Buscar Artículos" Shortcuts action (via `ItemQuery`,
/// an `EntityPropertyQuery`) and the parameter type of `RefreshItemIntent`.
struct ItemEntity: AppEntity {
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

    @Property(title: "Última comprobación")
    var lastCheckedAt: Date?

    init(item: Item) {
        id = item.id
        title = item.title
        store = item.store
        category = item.category ?? ""
        status = item.status
        priceCurrentCents = item.priceCurrentCents ?? 0
        lastCheckedAt = item.lastCheckedAt
    }

    var displayRepresentation: DisplayRepresentation {
        let priceText = priceCurrentCents > 0 ? String(format: "%.2f €", Double(priceCurrentCents) / 100) : "sin precio"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(store.displayName) · \(priceText)")
    }
}
