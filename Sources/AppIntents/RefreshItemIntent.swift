import AppIntents
import Foundation

struct RefreshItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Actualizar artículo"
    static let description = IntentDescription("Pide al servidor que compruebe el precio actual de un artículo y guarda el resultado.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Artículo")
    var item: ItemEntity

    init() {}

    init(item: ItemEntity) {
        self.item = item
    }

    func perform() async throws -> some IntentResult & ReturnsValue<RefreshResultEntity> & ProvidesDialog {
        // The server checks the price (POST /items/:id/refresh); nothing is read on device.
        guard let remote = AppEnvironment.shared.remoteStore else { throw PriceBucketError.notConfigured }
        guard remote.isConfigured else { throw PriceBucketError.notConfigured }
        let outcome = await Self.remoteOutcome(id: item.id, remote: remote)
        let text: String
        if let error = outcome.error { text = "No se pudo comprobar \(item.title): \(error)" }
        else if let cents = outcome.priceCents, let currency = outcome.currency {
            text = "\(item.title): \(MoneyFormatter.string(cents: cents, currency: currency)). \(outcome.changed ? "El precio ha cambiado." : "Sin cambios de precio.")"
        } else { text = "Comprobación terminada." }
        return .result(value: RefreshResultEntity(outcome: outcome), dialog: IntentDialog(stringLiteral: text))
    }
}

/// Result of one server-side check, as reported to Shortcuts.
struct ItemRefreshOutcome: Sendable {
    var itemID: UUID
    var priceCents: Int? = nil
    var currency: String? = nil
    var changed: Bool = false
    var checkedAt: Date? = nil
    var error: String? = nil
}

extension RefreshItemIntent {
    /// Server check mapped to an outcome. A deferred check (Amazon, blocked
    /// pages) reports the stored price with no error and no change.
    static func remoteOutcome(id: UUID, remote: RemoteItemStore) async -> ItemRefreshOutcome {
        do {
            let before = try await remote.item(id: id)
            let result = try await remote.refresh(id: id)
            let item = result.item
            return ItemRefreshOutcome(
                itemID: id, priceCents: item.priceCurrentCents, currency: item.currency,
                changed: before?.priceCurrentCents != item.priceCurrentCents,
                checkedAt: item.lastCheckedAt, error: item.lastError)
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
