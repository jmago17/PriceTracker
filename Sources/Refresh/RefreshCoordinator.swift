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

    init(itemStore: any PriceHistoryStoring, alertStore: any AlertStoring, connectorToFetch: @escaping @Sendable (Store) -> (any StoreConnector)?, now: @escaping @Sendable () -> Date = { Date() }, didRefresh: @escaping @Sendable () async -> Void = {}) {
        self.itemStore = itemStore
        self.alertStore = alertStore
        self.connectorToFetch = connectorToFetch
        self.now = now
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
        do {
            try Task.checkCancellation()
            guard let item = try await itemStore.item(id: id) else { throw RefreshError.itemNotFound }
            let (updated, alerts) = try await refresh(item)
            for alert in alerts {
                try await alertStore.append(PriceAlert(itemID: id, kind: alert.kind, priceFromCents: alert.fromCents, priceToCents: alert.toCents))
            }
            await didRefresh()
            return ItemRefreshOutcome(itemID: id, priceCents: updated.priceCurrentCents,
                currency: updated.currency, changed: updated.lastError == nil &&
                    (item.priceCurrentCents != updated.priceCurrentCents || item.currency != updated.currency),
                checkedAt: updated.lastCheckedAt, error: updated.lastError,
                dropped: alerts.contains { $0.kind == .drop || $0.kind == .targetHit || $0.kind == .lowRecord }, didPersist: true)
        } catch {
            return ItemRefreshOutcome(itemID: id, error: error.localizedDescription)
        }
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
        var summary = RefreshSummary()
        let total = items.count
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            await onProgress?(RefreshProgress(completed: index, total: total, currentTitle: item.title))

            guard Store.refreshableStores.contains(item.store) else {
                summary.skipped += 1
                continue
            }

            let result = await refreshResult(id: item.id)
            summary.checked += 1
            if result.error != nil { summary.failed += 1 }
            else if result.dropped { summary.dropped += 1 }
        }
        await onProgress?(RefreshProgress(completed: total, total: total, currentTitle: nil))
        return summary
    }

    /// Each successful fetch records an observation, even when the price is
    /// unchanged. Persistence failures propagate; they are not network failures.
    private func refresh(_ item: Item) async throws -> (Item, [PendingAlertDraft]) {
        guard let connector = connectorToFetch(item.store) else {
            var updated = item
            updated.lastError = "Sin conector de refresco para \(item.store.displayName)."
            return (try await itemStore.commitRefresh(updated, expected: item, observation: nil), [])
        }
        let result: FetchResult
        do {
            result = try await connector.fetch(item)
        } catch {
            try Task.checkCancellation()
            guard let latest = try await itemStore.item(id: item.id) else { throw RefreshError.itemNotFound }
            let failed = PriceDropDetector.applyFailure(to: latest, error: error, now: now())
            return (try await itemStore.commitRefresh(failed, expected: latest, observation: nil), [])
        }
        try Task.checkCancellation()
        // Re-read after network suspension so edits made during fetch survive.
        guard let current = try await itemStore.item(id: item.id), current.identityKey == item.identityKey else {
            throw RefreshError.itemNotFound
        }
        let now = now()
        let evaluation = PriceDropDetector.evaluate(item: current, fetch: result, now: now)
        let observation = PriceObservation(itemID: item.id, checkedAt: now,
            priceCents: result.priceCents, currency: result.currency.uppercased(),
            isOnSale: result.isOnSale, saleEndsAt: result.saleEndsAt, availability: result.availability)
        let stored = try await itemStore.commitRefresh(evaluation.updatedItem, expected: current, observation: observation)
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
}
