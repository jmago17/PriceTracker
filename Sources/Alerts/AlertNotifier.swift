import Foundation
@preconcurrency import UserNotifications

/// Serial delivery shared by all refresh entry points. Never requests permission.
actor AlertNotifier {
    private let alertStore: any AlertStoring
    private let itemStore: any ItemStoring
    private var delivering = false
    private let enabled: @Sendable () -> Bool
    private let authorized: @Sendable () async -> Bool
    private let deliver: @Sendable (String, String, String) async throws -> Void

    init(alertStore: any AlertStoring, itemStore: any ItemStoring,
         enabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "notifyPriceChanges") },
         authorized: @escaping @Sendable () async -> Bool = {
             let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
             return status == .authorized || status == .provisional
         },
         deliver: @escaping @Sendable (String, String, String) async throws -> Void = { id, title, body in
             let content = UNMutableNotificationContent()
             content.title = title
             content.body = body
             content.sound = .default
             try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
         }) {
        self.alertStore = alertStore
        self.itemStore = itemStore
        self.enabled = enabled
        self.authorized = authorized
        self.deliver = deliver
    }

    /// Returns the number of items included in the summary (0 = nothing to notify,
    /// no notification posted).
    @discardableResult
    func notifyPendingDrops() async throws -> Int {
        guard !delivering else { return 0 }
        delivering = true
        defer { delivering = false }
        guard enabled(), await authorized() else { return 0 }
        let pending = try await alertStore.pendingAlerts()
        guard !pending.isEmpty else { return 0 }

        let items = try await itemStore.loadAll()
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let latest = Dictionary(grouping: pending, by: \.itemID).values.compactMap { $0.last }
            .filter { itemsByID[$0.itemID] != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let lines = latest.prefix(6).compactMap { alert -> String? in
            guard let item = itemsByID[alert.itemID] else { return nil }
            return Self.line(for: alert, item: item)
        }

        guard enabled() else { return 0 }
        guard !latest.isEmpty else {
            try await alertStore.markSent(ids: Set(pending.map(\.id)))
            return 0
        }
        let title = latest.count == 1 ? "1 artículo con cambios de precio" : "\(latest.count) artículos con cambios de precio"
        // Stable for a retry if delivery succeeds but persisting sentAt fails.
        let identifier = "price-changes-" + pending.map { $0.id.uuidString }.sorted().joined(separator: "-")
        try await deliver(identifier, title, lines.joined(separator: "\n"))

        try await alertStore.markSent(ids: Set(pending.map(\.id)))
        return latest.count
    }

    private static func line(for alert: PriceAlert, item: Item) -> String {
        let from = alert.priceFromCents.map { MoneyFormatter.string(cents: $0, currency: item.currency) } ?? "?"
        let to = MoneyFormatter.string(cents: alert.priceToCents ?? 0, currency: item.currency)
        switch alert.kind {
        case .priceChange, .drop:
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

}
