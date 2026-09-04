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

/// Drives every "refresh" path in the app: a single item (also the body of the
/// `RefreshItem` App Intent), a category, or the whole catalog. Deliberately NOT
/// one monolithic "RunPriceCheck" — see project brief and
/// /tmp/josu_pushback2.md for why that shape was rejected.
///
/// An `actor` so overlapping calls (e.g. the UI triggers "refresh all" while the
/// `RefreshItem` intent fires from Shortcuts) don't race on the same file-backed
/// store.
actor RefreshCoordinator {
    private let itemStore: any ItemStoring
    private let alertStore: any AlertStoring
    private let connectors: ConnectorRegistry

    init(itemStore: any ItemStoring, alertStore: any AlertStoring, connectors: ConnectorRegistry) {
        self.itemStore = itemStore
        self.alertStore = alertStore
        self.connectors = connectors
    }

    /// Refreshes one item. Returns `true` if the fetch succeeded (regardless of
    /// whether the price moved). Throws only for programmer errors (item not
    /// found); connector failures are recorded on the item, not thrown.
    @discardableResult
    func refreshItem(id: UUID) async throws -> Bool {
        guard let item = try await itemStore.item(id: id) else {
            throw RefreshError.itemNotFound
        }
        let (updated, alerts) = await refresh(item)
        try await itemStore.upsert(updated)
        for alert in alerts {
            try await alertStore.append(PriceAlert(itemID: updated.id, kind: alert.kind, priceFromCents: alert.fromCents, priceToCents: alert.toCents))
        }
        return updated.lastError == nil
    }

    func refreshCategory(_ category: String?, onProgress: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil) async throws -> RefreshSummary {
        let items = try await itemStore.loadAll().filter { $0.category == category && $0.status != .archived }
        return try await refreshBatch(items, onProgress: onProgress)
    }

    /// Refreshes every active item. Cooperatively cancelable: callers hold the
    /// `Task` this runs in and call `.cancel()`; we check `Task.isCancelled`
    /// between items so a cancel takes effect within one network round-trip,
    /// never mid-write. `onProgress` is `@MainActor` so a SwiftUI view model can
    /// pass a closure that touches its own state directly, with no manual hop.
    func refreshCatalog(onProgress: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil) async throws -> RefreshSummary {
        let items = try await itemStore.loadAll().filter { $0.status != .archived }
        return try await refreshBatch(items, onProgress: onProgress)
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

            let (updated, alerts) = await refresh(item)
            try await itemStore.upsert(updated)
            for alert in alerts {
                try await alertStore.append(PriceAlert(itemID: updated.id, kind: alert.kind, priceFromCents: alert.fromCents, priceToCents: alert.toCents))
            }
            summary.checked += 1
            if updated.lastError != nil {
                summary.failed += 1
            } else if !alerts.isEmpty {
                summary.dropped += 1
            }
        }
        await onProgress?(RefreshProgress(completed: total, total: total, currentTitle: nil))
        return summary
    }

    /// Fetches + evaluates a single item without touching the store — used by
    /// both the per-item and batch paths so they share one code path.
    private func refresh(_ item: Item) async -> (Item, [PendingAlertDraft]) {
        guard let connector = connectors.connectorToFetch(store: item.store) else {
            var updated = item
            updated.lastError = "Sin conector de refresco para \(item.store.displayName)."
            return (updated, [])
        }
        do {
            let result = try await connector.fetch(item)
            let evaluation = PriceDropDetector.evaluate(item: item, fetch: result)
            return (evaluation.updatedItem, evaluation.alerts)
        } catch {
            return (PriceDropDetector.applyFailure(to: item, error: error), [])
        }
    }
}

enum RefreshError: Error, LocalizedError {
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .itemNotFound: return "El artículo ya no existe."
        }
    }
}
