import AppIntents
import Foundation

struct GetItemPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Consultar precio"
    static let description = IntentDescription("Dice el precio guardado de un artículo del catálogo.", categoryName: "Consultar")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true

    @Parameter(title: "Artículo", requestValueDialog: IntentDialog("¿Qué artículo?"))
    var item: ItemEntity

    init() {}
    init(item: ItemEntity) { self.item = item }

    static var parameterSummary: some ParameterSummary {
        Summary("Consultar el precio de \(\.$item)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> & ProvidesDialog {
        guard let current = try await AppEnvironment.shared.itemStore.item(id: item.id) else {
            throw PriceQueryError.itemNoLongerExists
        }
        let entity = ItemEntity(item: current)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: Self.spokenSummary(for: current)))
    }

    static func spokenSummary(for item: Item) -> String {
        guard let cents = item.priceCurrentCents else { return "Todavía no hay precio guardado de \(item.title)." }
        if cents == 0 { return "\(item.title) está gratis en \(item.store.displayName)." }
        let price = MoneyFormatter.string(cents: cents, currency: item.currency)
        guard let target = item.targetPriceCents else { return "\(item.title) cuesta \(price) en \(item.store.displayName)." }
        if cents <= target { return "\(item.title) cuesta \(price), por debajo de tu objetivo." }
        let remaining = MoneyFormatter.string(cents: cents - target, currency: item.currency)
        return "\(item.title) cuesta \(price). Faltan \(remaining) para tu objetivo."
    }
}

enum PriceQueryError: Error, CustomLocalizedStringResourceConvertible {
    case itemNoLongerExists
    var localizedStringResource: LocalizedStringResource { "Ese artículo ya no está en el catálogo." }
}
