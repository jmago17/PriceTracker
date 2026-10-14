import Foundation
@preconcurrency import UserNotifications

/// Serial delivery shared by all refresh entry points. Never requests permission.
actor AlertNotifier {
    private let alertStore: any AlertStoring
    private let itemStore: any ItemStoring
    private var delivering = false
    private let enabled: @Sendable () -> Bool
    private let timeSensitiveEnabled: @Sendable () -> Bool
    private let authorized: @Sendable () async -> Bool
    private let deliver: @Sendable (String, String, String, Bool) async throws -> Void

    init(alertStore: any AlertStoring, itemStore: any ItemStoring,
         enabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "notifyPriceChanges") },
         timeSensitiveEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "timeSensitivePriceDeals") },
         authorized: @escaping @Sendable () async -> Bool = {
             let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
             return status == .authorized || status == .provisional
         },
         deliver: @escaping @Sendable (String, String, String, Bool) async throws -> Void = { id, title, body, timeSensitive in
             let content = UNMutableNotificationContent()
             content.title = title
             content.body = body
             content.sound = .default
             let settings = await UNUserNotificationCenter.current().notificationSettings()
             content.interruptionLevel = AlertNotifier.interruptionLevel(timeSensitive: timeSensitive, allowed: settings.timeSensitiveSetting == .enabled)
             try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
         }) {
        self.alertStore = alertStore
        self.itemStore = itemStore
        self.enabled = enabled
        self.authorized = authorized
        self.timeSensitiveEnabled = timeSensitiveEnabled
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
            .filter { alert in
                guard let item = itemsByID[alert.itemID] else { return false }
                if let currency = alert.currency, currency.caseInsensitiveCompare(item.currency) != .orderedSame { return false }
                if alert.kind == .priceChange {
                    return alert.initialPriceAlertKey == item.initialPriceAlertKey && alert.initialPriceAlertKey != nil
                }
                return true
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard enabled() else { return 0 }
        let optedIn = timeSensitiveEnabled()
        let groups = Dictionary(grouping: latest) { alert in
            Self.qualifiesForTimeSensitive(alert, item: itemsByID[alert.itemID]!, optedIn: optedIn)
        }
        // Do not elevate unrelated articles in a mixed summary.
        for timeSensitive in [false, true] {
            guard let group = groups[timeSensitive], !group.isEmpty else { continue }
            let lines = group.prefix(6).map { Self.line(for: $0, item: itemsByID[$0.itemID]!) }
            let es = CatalogLanguage.isSpanish
            let title: String
            if es {
                title = group.count == 1 ? "1 artículo con cambios de precio" : "\(group.count) artículos con cambios de precio"
            } else {
                title = group.count == 1 ? "1 item with price changes" : "\(group.count) items with price changes"
            }
            // Stable for retries, even if a prior group was already delivered.
            let identifier = "price-changes-" + group.map { $0.id.uuidString }.sorted().joined(separator: "-")
            try await deliver(identifier, title, lines.joined(separator: "\n"), timeSensitive)
            let deliveredItems = Set(group.map(\.itemID))
            try await alertStore.markSent(ids: Set(pending.filter { deliveredItems.contains($0.itemID) }.map(\.id)))
        }
        try await alertStore.markSent(ids: Set(pending.map(\.id)))
        return latest.count
    }

    static func interruptionLevel(timeSensitive: Bool, allowed: Bool) -> UNNotificationInterruptionLevel {
        timeSensitive && allowed ? .timeSensitive : .active
    }

    static func qualifiesForTimeSensitive(_ alert: PriceAlert, item: Item, optedIn: Bool, now: Date = Date()) -> Bool {
        guard optedIn, item.priority == .high, item.status == .active,
              item.lastError == nil, let end = alert.confirmedSaleEndsAt, end > now,
              // The latest successful fetch clears this if it disconfirms the sale.
              let observedEnd = item.onSaleUntil,
              // JSON's Unix-epoch conversion can lose sub-microsecond Date precision.
              abs(observedEnd.timeIntervalSince(end)) < 0.001, let from = alert.priceFromCents,
              let to = alert.priceToCents, to < from, item.priceCurrentCents == to else { return false }
        return alert.kind == .drop || alert.kind == .targetHit || alert.kind == .lowRecord
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
