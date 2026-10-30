import AppIntents
import Foundation

struct RefreshItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Actualizar artículo"
    static let description = IntentDescription("Comprueba el precio actual de un artículo y guarda el resultado.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Artículo")
    var item: ItemEntity

    init() {}

    init(item: ItemEntity) {
        self.item = item
    }

    func perform() async throws -> some IntentResult & ReturnsValue<RefreshResultEntity> & ProvidesDialog {
        let outcome: ItemRefreshOutcome
        if let remote = AppEnvironment.shared.remoteStore {
            guard remote.isConfigured else { throw PriceBucketError.notConfigured }
            outcome = await Self.remoteOutcome(id: item.id, remote: remote)
        } else {
            outcome = await AppEnvironment.shared.refreshCoordinator.refreshResult(id: item.id)
        }
        let text: String
        if let error = outcome.error { text = "No se pudo comprobar \(item.title): \(error)" }
        else if let cents = outcome.priceCents, let currency = outcome.currency {
            text = "\(item.title): \(MoneyFormatter.string(cents: cents, currency: currency)). \(outcome.changed ? "El precio ha cambiado." : "Sin cambios de precio.")"
        } else { text = "Comprobación terminada." }
        return .result(value: RefreshResultEntity(outcome: outcome), dialog: IntentDialog(stringLiteral: text))
    }
}

extension RefreshItemIntent {
    /// Server check mapped to the existing outcome. A deferred check (Amazon,
    /// blocked pages) reports the stored price with no error and no change.
    static func remoteOutcome(id: UUID, remote: RemoteItemStore) async -> ItemRefreshOutcome {
        do {
            let before = try await remote.item(id: id)
            let result = try await remote.refresh(id: id)
            let item = result.item
            return ItemRefreshOutcome(
                itemID: id, priceCents: item.priceCurrentCents, currency: item.currency,
                changed: before?.priceCurrentCents != item.priceCurrentCents,
                checkedAt: item.lastCheckedAt, error: item.lastError, dropped: false, didPersist: true)
        } catch {
            return ItemRefreshOutcome(itemID: id, error: error.localizedDescription)
        }
    }
}

/// A value for each loop iteration, including failed/deleted items.
struct RefreshResultEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Resultado de actualización" }
    @Property(title: "ID del artículo") var itemID: String
    @Property(title: "Precio (céntimos)") var priceCents: Int?
    @Property(title: "Moneda") var currency: String?
    @Property(title: "Ha cambiado") var changed: Bool
    @Property(title: "Comprobación correcta") var success: Bool
    @Property(title: "Comprobado el") var checkedAt: Date?
    @Property(title: "Error") var error: String?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(success ? "Comprobado" : "Error")", subtitle: "\(error ?? currency ?? "")")
    }
    init() {
        itemID = ""
        changed = false
        success = false
    }
    init(outcome: ItemRefreshOutcome) {
        itemID = outcome.itemID.uuidString
        priceCents = outcome.priceCents
        currency = outcome.currency
        changed = outcome.changed
        success = outcome.error == nil
        checkedAt = outcome.checkedAt
        error = outcome.error
    }
}
