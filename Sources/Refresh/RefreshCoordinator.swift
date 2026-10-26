import Foundation

struct RefreshProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var currentTitle: String?
}

struct RefreshSummary: Equatable, Sendable {
    var checked: Int = 0
    var dropped: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var skippedStores: Set<Store> = []
    var cancelled = false
    var notificationError: String? = nil

    var completionMessage: String {
        var parts = [cancelled ? "Comprobación cancelada." : "Comprobación finalizada.",
                     "Actualizados: \(max(0, checked - failed)). Errores: \(failed)."]
        if skipped > 0 {
            let stores = skippedStores.map(\.displayName).sorted().joined(separator: ", ")
            parts.append("Sin comprobar: \(skipped)" + (stores.isEmpty ? "." : " (\(stores))."))
            parts.append("Estas tiendas no tienen seguimiento de precios disponible; su fecha no se actualiza.")
        }
        if checked == 0 && skipped == 0 && !cancelled { parts.append("No hay artículos activos que comprobar.") }
        if failed > 0 { parts.append("Los artículos con error conservan la fecha de su última comprobación correcta. Abre su detalle y toca Ver diagnóstico de comprobación para ver o compartir el motivo.") }
        if notificationError != nil { parts.append("Hay alertas guardadas pendientes de entrega; se reintentarán sin volver a comprobar el precio.") }
        return parts.joined(separator: " ")
    }
}

/// Shared by foreground, background and App Intents in the app process.
actor RefreshCoordinator {
    private let itemStore: any PriceHistoryStoring
    private let alertStore: any AlertStoring
    private let connectorToFetch: @Sendable (Store) -> (any StoreConnector)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let didRefresh: @Sendable () async -> Void

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private let now: @Sendable () -> Date
    private let diagnostics: RefreshDiagnostics

    init(itemStore: any PriceHistoryStoring, alertStore: any AlertStoring, connectorToFetch: @escaping @Sendable (Store) -> (any StoreConnector)?, now: @escaping @Sendable () -> Date = { Date() }, diagnostics: RefreshDiagnostics = .shared, didRefresh: @escaping @Sendable () async -> Void = {}) {
        self.itemStore = itemStore
        self.alertStore = alertStore
        self.connectorToFetch = connectorToFetch
        self.now = now
        self.diagnostics = diagnostics
        self.didRefresh = didRefresh
    }

    /// Refreshes one item. Returns `true` if the fetch succeeded (regardless of
    /// whether the price moved). The typed result preserves per-item errors.
    @discardableResult
    func refreshItem(id: UUID) async throws -> Bool {
        let result = await refreshResult(id: id)
        if let error = result.error, !result.didPersist { throw RefreshError.failed(error) }
        return result.error == nil
    }

    func refreshResult(id: UUID) async -> ItemRefreshOutcome {
        await acquire()
        defer { release() }
        let attemptID = UUID(), startedAt = Date(), clock = ContinuousClock.now
        var store: Store?
        var lastSuccessAt: Date?
        var phase = RefreshDiagnosticPhase.loading
        var fetchFailure: RefreshDiagnosticFailure?
        do {
            try Task.checkCancellation()
            guard let item = try await itemStore.item(id: id) else { throw RefreshError.itemNotFound }
            store = item.store
            lastSuccessAt = item.lastSuccessAt
            let (updated, alerts) = try await refresh(item, failure: &fetchFailure, phase: &phase)
            lastSuccessAt = updated.lastSuccessAt
            var notificationError: String?
            var alertFailure: RefreshDiagnosticFailure?
            phase = .alerts
            do {
                if itemStore is any AlertOutboxStoring {
                    try await AlertOutboxDelivery.flush(itemStore: itemStore, alertStore: alertStore)
                } else {
                    // Lightweight legacy/in-memory stores only. Both production
                    // stores implement AlertOutboxStoring (including demo SQLite).
                    for alert in Self.priceAlerts(alerts, item: updated) { try await alertStore.append(alert) }
                }
            } catch {
                alertFailure = RefreshDiagnosticFailure.classify(error, phase: .alerts)
                notificationError = alertFailure?.errorDescription
            }
            let elapsed = clock.duration(to: .now).components
            await diagnostics.record(RefreshDiagnosticAttempt(id: attemptID, itemID: id, store: store,
                startedAt: startedAt, duration: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                lastSuccessAt: lastSuccessAt, failure: fetchFailure, alertFailure: alertFailure))
            await didRefresh()
            return ItemRefreshOutcome(itemID: id, priceCents: updated.priceCurrentCents,
                currency: updated.currency, changed: updated.lastError == nil &&
                    (item.priceCurrentCents != updated.priceCurrentCents || item.currency != updated.currency),
                checkedAt: updated.lastCheckedAt, error: updated.lastError,
                dropped: alerts.contains { $0.kind == .drop || $0.kind == .targetHit || $0.kind == .lowRecord }, didPersist: true, notificationError: notificationError)
        } catch {
            let failure = RefreshDiagnosticFailure.classify(error, phase: phase)
            let elapsed = clock.duration(to: .now).components
            await diagnostics.record(RefreshDiagnosticAttempt(id: attemptID, itemID: id, store: store,
                startedAt: startedAt, duration: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                lastSuccessAt: lastSuccessAt, failure: failure, alertFailure: nil, precedingFailure: fetchFailure))
            return ItemRefreshOutcome(itemID: id, error: failure.errorDescription)
        }
    }

    /// Called on launch/reactivation too. An append/ack failure leaves its UUID
    /// durable; retries never regenerate drafts from the now-unchanged price.
    func retryPendingAlerts() async throws {
        await acquire()
        defer { release() }
        guard let outbox = itemStore as? any AlertOutboxStoring else { return }
        let deliveries = try await outbox.pendingAlertDeliveries()
        let pendingNotifications = try await alertStore.pendingAlerts()
        guard !deliveries.isEmpty || !pendingNotifications.isEmpty else { return }
        try await AlertOutboxDelivery.flush(itemStore: itemStore, alertStore: alertStore)
        await didRefresh()
    }

    private static func priceAlerts(_ drafts: [PendingAlertDraft], item: Item) -> [PriceAlert] {
        drafts.map { PriceAlert(itemID: item.id, kind: $0.kind, priceFromCents: $0.fromCents,
            priceToCents: $0.toCents, confirmedSaleEndsAt: $0.confirmedSaleEndsAt,
            initialPriceAlertKey: $0.kind == .priceChange ? item.initialPriceAlertKey : nil, currency: item.currency) }
    }

    func refreshCategory(_ category: String?, onProgress: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil) async throws -> RefreshSummary {
        let items = try await itemStore.loadAll().filter { $0.category == category && $0.status != .archived }
        return try await refreshBatch(ItemFilterEngine.sort(items, by: .lastCheckedAt, ascending: true), onProgress: onProgress)
    }

    /// Refreshes every active item. Cooperatively cancelable: callers hold the
    /// `Task` this runs in and call `.cancel()`; we check `Task.isCancelled`
    /// between items so a cancel takes effect within one network round-trip,
    /// never mid-write. `onProgress` is `@MainActor` so a SwiftUI view model can
    /// pass a closure that touches its own state directly, with no manual hop.
    func refreshCatalog(onProgress: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil) async throws -> RefreshSummary {
        let items = try await itemStore.loadAll().filter { $0.status != .archived }
        return try await refreshBatch(ItemFilterEngine.sort(items, by: .lastCheckedAt, ascending: true), onProgress: onProgress)
    }

    private func refreshBatch(_ items: [Item], onProgress: (@MainActor @Sendable (RefreshProgress) -> Void)?) async throws -> RefreshSummary {
        // Also retry on empty catalogs/unsupported stores; no new price needed.
        var summary = RefreshSummary()
        do { try await retryPendingAlerts() }
        catch { summary.notificationError = RefreshDiagnosticCode.alerts.message }
        let total = items.count
        for (index, item) in items.enumerated() {
            if Task.isCancelled { summary.cancelled = true; break }
            await onProgress?(RefreshProgress(completed: index, total: total, currentTitle: item.title))

            guard Store.refreshableStores.contains(item.store) else {
                summary.skipped += 1
                summary.skippedStores.insert(item.store)
                continue
            }

            let result = await refreshResult(id: item.id)
            if let error = result.notificationError { summary.notificationError = error }
            summary.checked += 1
            if result.error != nil { summary.failed += 1 }
            else if result.dropped { summary.dropped += 1 }
        }
        summary.cancelled = summary.cancelled || Task.isCancelled
        await onProgress?(RefreshProgress(completed: summary.checked + summary.skipped, total: total, currentTitle: nil))
        return summary
    }

    /// Each successful fetch records an observation, even when the price is
    /// unchanged. Persistence failures propagate; they are not network failures.
    private func refresh(_ item: Item, failure: inout RefreshDiagnosticFailure?, phase: inout RefreshDiagnosticPhase) async throws -> (Item, [PendingAlertDraft]) {
        guard let connector = connectorToFetch(item.store) else {
            failure = RefreshDiagnosticFailure(code: .unsupported, phase: .validation)
            var updated = item
            updated.lastError = failure?.errorDescription
            phase = .persistence
            return (try await itemStore.commitRefresh(updated, expected: item, observation: nil), [])
        }
        let result: FetchResult
        phase = .download
        do {
            result = try await connector.fetch(item)
            guard result.priceCents >= 0 else { throw ConnectorError.decoding("Precio negativo") }
        } catch {
            try Task.checkCancellation()
            let safeFailure = RefreshDiagnosticFailure.classify(error, phase: phase)
            failure = safeFailure
            phase = .persistence
            guard let latest = try await itemStore.item(id: item.id) else { throw RefreshError.itemNotFound }
            let failed = PriceDropDetector.applyFailure(to: latest, error: safeFailure, now: now())
            return (try await itemStore.commitRefresh(failed, expected: latest, observation: nil), [])
        }
        try Task.checkCancellation()
        phase = .persistence
        // Re-read after network suspension so edits made during fetch survive.
        guard let current = try await itemStore.item(id: item.id), current.identityKey == item.identityKey else {
            throw RefreshError.itemNotFound
        }
        let now = now()
        let evaluation = PriceDropDetector.evaluate(item: current, fetch: result, now: now)
        let observation = PriceObservation(itemID: item.id, checkedAt: now,
            priceCents: result.priceCents, currency: result.currency.uppercased(),
            isOnSale: result.isOnSale, saleEndsAt: result.saleEndsAt, availability: result.availability)
        let stored: Item
        if let outbox = itemStore as? any AlertOutboxStoring {
            stored = try await outbox.commitRefresh(evaluation.updatedItem, expected: current,
                observation: observation, alerts: Self.priceAlerts(evaluation.alerts, item: evaluation.updatedItem))
        } else {
            stored = try await itemStore.commitRefresh(evaluation.updatedItem, expected: current, observation: observation)
        }
        return (stored, evaluation.alerts)
    }
}

enum RefreshError: Error, LocalizedError {
    case itemNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .itemNotFound: return "El artículo ya no existe."
        }
    }
}

struct ItemRefreshOutcome: Sendable {
    var itemID: UUID
    var priceCents: Int? = nil
    var currency: String? = nil
    var changed: Bool = false
    var checkedAt: Date? = nil
    var error: String? = nil
    var dropped: Bool = false
    var didPersist: Bool = false
    /// The price committed; notification persistence will retry independently.
    var notificationError: String? = nil
}

/// At-least-once outbox dispatch, exactly-once durable alert IDs. Not a CloudKit
/// transport. Notification delivery keeps its existing sentAt/permission policy.
enum AlertOutboxDelivery {
    static func flush(itemStore: any ItemStoring, alertStore: any AlertStoring) async throws {
        guard let outbox = itemStore as? any AlertOutboxStoring else { return }
        for alert in try await outbox.pendingAlertDeliveries() {
            try await alertStore.append(alert)
            try await outbox.acknowledgeAlertDelivery(id: alert.id)
        }
    }
}
