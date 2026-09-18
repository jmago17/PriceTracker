import AppIntents
import Foundation

struct SetTargetPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Fijar precio objetivo"
    static let description = IntentDescription("Guarda el precio objetivo de un artículo para avisarte cuando lo alcance.", categoryName: "Editar")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true

    @Parameter(title: "Artículo", requestValueDialog: IntentDialog("¿Qué artículo?")) var item: ItemEntity
    @Parameter(title: "Precio objetivo", requestValueDialog: IntentDialog("¿Qué precio objetivo?")) var targetPrice: Double

    init() {}
    init(item: ItemEntity, targetPrice: Double) { self.item = item; self.targetPrice = targetPrice }

    static var parameterSummary: some ParameterSummary {
        Summary("Avisarme cuando \(\.$item) baje a \(\.$targetPrice)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> & ProvidesDialog {
        let store = AppEnvironment.shared.itemStore
        guard var current = try await store.item(id: item.id) else { throw PriceQueryError.itemNoLongerExists }
        guard targetPrice >= 0 else { throw TargetPriceError.negativeAmount }
        let cents = Int((targetPrice * 100).rounded())
        current.targetPriceCents = cents
        current.lastAlertedPriceCents = nil
        current.updatedAt = Date()
        let saved = try await store.upsert(current)
        let formatted = MoneyFormatter.string(cents: cents, currency: saved.currency)
        return .result(value: ItemEntity(item: saved), dialog: IntentDialog(stringLiteral: "Te avisaré cuando \(saved.title) baje a \(formatted)."))
    }
}

enum TargetPriceError: Error, CustomLocalizedStringResourceConvertible {
    case negativeAmount
    var localizedStringResource: LocalizedStringResource { "El precio objetivo no puede ser negativo." }
}
