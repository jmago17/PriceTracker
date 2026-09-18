import AppIntents
import Foundation

struct ShowPriceDropsIntent: AppIntent {
    static let title: LocalizedStringResource = "Ver bajadas de precio"
    static let description = IntentDescription("Enumera los artículos que han bajado de precio desde que los añadiste.", categoryName: "Consultar")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = true
    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> & ProvidesDialog {
        let dropped = Self.discountedItems(in: try await AppEnvironment.shared.itemStore.loadAll())
        return .result(value: dropped.map(ItemEntity.init(item:)), dialog: IntentDialog(stringLiteral: Self.spokenSummary(for: dropped)))
    }

    static func discountedItems(in items: [Item]) -> [Item] {
        items.filter { $0.status != .archived }.filter {
            guard let current = $0.priceCurrentCents, let atAdd = $0.priceAtAddCents else { return false }
            return current < atAdd
        }.sorted {
            (($0.priceAtAddCents ?? 0) - ($0.priceCurrentCents ?? 0)) > (($1.priceAtAddCents ?? 0) - ($1.priceCurrentCents ?? 0))
        }
    }

    static func spokenSummary(for items: [Item]) -> String {
        guard let first = items.first else { return "Ningún artículo ha bajado de precio." }
        let saving = MoneyFormatter.string(cents: (first.priceAtAddCents ?? 0) - (first.priceCurrentCents ?? 0), currency: first.currency)
        if items.count == 1 { return "\(first.title) ha bajado \(saving)." }
        return "\(items.count) artículos han bajado. El mayor descuento es \(first.title), con \(saving) menos."
    }
}
