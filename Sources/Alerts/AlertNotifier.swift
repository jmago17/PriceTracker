import Foundation
@preconcurrency import UserNotifications

/// Posts a single local notification summarizing every undelivered alert, then
/// marks them sent. Deliberately separate from `RefreshItem` (per
/// /tmp/josu_pushback2.md's accepted design: Shortcuts calls this once, at the
/// end of the "Repeat with each RefreshItem" loop) — one summary, not N pushes.
struct AlertNotifier: Sendable {
    private let alertStore: any AlertStoring
    private let itemStore: any ItemStoring
    private let center: UNUserNotificationCenter

    init(alertStore: any AlertStoring, itemStore: any ItemStoring, center: UNUserNotificationCenter = .current()) {
        self.alertStore = alertStore
        self.itemStore = itemStore
        self.center = center
    }

    /// Returns the number of alerts included in the summary (0 = nothing to notify,
    /// no notification posted).
    @discardableResult
    func notifyPendingDrops() async throws -> Int {
        let pending = try await alertStore.pendingAlerts()
        guard !pending.isEmpty else { return 0 }

        let items = try await itemStore.loadAll()
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let lines = pending.prefix(6).compactMap { alert -> String? in
            guard let item = itemsByID[alert.itemID] else { return nil }
            return Self.line(for: alert, item: item)
        }

        let content = UNMutableNotificationContent()
        content.title = pending.count == 1 ? "1 bajada de precio" : "\(pending.count) bajadas de precio"
        content.body = lines.joined(separator: "\n")
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)

        try await alertStore.markSent(ids: Set(pending.map(\.id)))
        return pending.count
    }

    private static func line(for alert: PriceAlert, item: Item) -> String {
        let from = alert.priceFromCents.map(formatCents) ?? "?"
        let to = formatCents(alert.priceToCents ?? 0)
        switch alert.kind {
        case .drop:
            return "\(item.title): \(from)→\(to)"
        case .targetHit:
            return "\(item.title): \(to) (objetivo alcanzado)"
        case .lowRecord:
            return "\(item.title): \(to) (mínimo histórico)"
        case .unavailable:
            return "\(item.title): ya no disponible"
        case .stale:
            return "\(item.title): sin poder comprobarse"
        }
    }

    private static func formatCents(_ cents: Int) -> String {
        String(format: "%.2f€", Double(cents) / 100)
    }
}
