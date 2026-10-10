import Foundation
import Observation
#if os(iOS)
import BackgroundTasks
#endif
@preconcurrency import UserNotifications

/// Preferences and OS scheduling are device-local, independent of CloudKit.
@MainActor @Observable
final class DailyRefreshSettings {
    static let taskID = "com.maromeapps.PriceTracker.daily-prices"
    static let shared = DailyRefreshSettings()
    private let defaults: UserDefaults
    private let submit: (Date) throws -> Void
    private let cancel: () -> Void
    private let authorize: () async throws -> Bool
    private let prepareNotifications: () async throws -> Void
    private let refresh: @Sendable () async -> Void
    private var running: Task<Void, Never>?
    private var permissionGeneration = 0
    var dailyEnabled: Bool
    var notificationsEnabled: Bool
    var message: String?
    var requestingPermission = false

    init(defaults: UserDefaults = .standard,
         submit: @escaping (Date) throws -> Void = { date in
             #if os(iOS)
             let request = BGAppRefreshTaskRequest(identifier: DailyRefreshSettings.taskID)
             request.earliestBeginDate = date
             try BGTaskScheduler.shared.submit(request)
             #endif
         },
         cancel: @escaping () -> Void = {
             #if os(iOS)
             BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: DailyRefreshSettings.taskID)
             #endif
         },
         authorize: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         },
         refresh: @escaping @Sendable () async -> Void = {
             _ = try? await AppEnvironment.shared.refreshCoordinator.refreshCatalog()
         },
         prepareNotifications: @escaping () async throws -> Void = {
             let store = AppEnvironment.shared.alertStore
             let pending = try await store.pendingAlerts()
             try await store.markSent(ids: Set(pending.map(\.id)), at: Date())
         }) {
        self.refresh = refresh
        self.defaults = defaults
        self.submit = submit
        self.cancel = cancel
        self.authorize = authorize
        self.prepareNotifications = prepareNotifications
        dailyEnabled = defaults.bool(forKey: "dailyPrices")
        notificationsEnabled = defaults.bool(forKey: "notifyPriceChanges")
    }

    func setDailyEnabled(_ enabled: Bool) {
        dailyEnabled = enabled
        defaults.set(enabled, forKey: "dailyPrices")
        if enabled { schedule() }
        else { cancel(); running?.cancel() }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        permissionGeneration += 1
        let generation = permissionGeneration
        if !enabled {
            notificationsEnabled = false
            defaults.set(false, forKey: "notifyPriceChanges")
            return
        }
        requestingPermission = true
        defer { requestingPermission = false }
        do {
            let granted = try await authorize()
            guard generation == permissionGeneration else { return }
            if granted { try await prepareNotifications() }
            guard generation == permissionGeneration else { return }
            notificationsEnabled = granted
            defaults.set(granted, forKey: "notifyPriceChanges")
            message = granted ? nil : "Los avisos están desactivados. Puedes permitirlos en Ajustes del sistema → PriceTracker."
        } catch { message = error.localizedDescription }
    }

    func schedule(now: Date = Date()) {
        guard dailyEnabled else { cancel(); return }
        let next = (defaults.object(forKey: "nextDailyPriceCheck") as? Date) ?? now.addingTimeInterval(86400)
        defaults.set(next, forKey: "nextDailyPriceCheck")
        do { try submit(max(now, next)); message = nil }
        catch { message = "No se pudo programar la actualización: \(error.localizedDescription)" }
    }

    func run() async {
        guard dailyEnabled, running == nil else { return }
        // Schedule the next opportunity before work, even if iOS expires this run.
        defaults.set(Date().addingTimeInterval(86400), forKey: "nextDailyPriceCheck")
        schedule()
        let task = Task { await refresh() }
        running = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        running = nil
    }
}
