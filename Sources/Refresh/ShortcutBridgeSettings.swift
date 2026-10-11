import Foundation
import Observation
@preconcurrency import UserNotifications

/// Device-local opt-in. These identifiers never overlap with price-change alerts.
struct ShortcutBridgeSchedule: Equatable, Sendable {
    static let dailyID = "pricetracker.shortcut-bridge.daily"
    static let testID = "pricetracker.shortcut-bridge.test"
    static let identifiers = [dailyID, testID]
    static let title = "PriceTracker.bridge"
    static let body = "PriceTracker refresh"
    let hour: Int
    let minute: Int

    init(hour: Int = 9, minute: Int = 0) {
        self.hour = (0...23).contains(hour) ? hour : 9
        self.minute = (0...59).contains(minute) ? minute : 0
    }

    var components: DateComponents { DateComponents(hour: hour, minute: minute) }

    func request(test: Bool = false) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = Self.body
        content.sound = nil
        content.badge = nil
        content.interruptionLevel = .passive
        let trigger: UNNotificationTrigger = test
            ? UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            : UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        return UNNotificationRequest(identifier: test ? Self.testID : Self.dailyID,
                                     content: content, trigger: trigger)
    }
}

@MainActor @Observable
final class ShortcutBridgeSettings {
    static let shared = ShortcutBridgeSettings()
    static let enabledKey = "shortcutBridgeEnabled"
    static let hourKey = "shortcutBridgeHour"
    static let minuteKey = "shortcutBridgeMinute"

    private let defaults: UserDefaults
    private let status: () async -> UNAuthorizationStatus
    private let authorize: () async throws -> Bool
    private let add: (UNNotificationRequest) async throws -> Void
    private let remove: ([String]) -> Void
    private let cancelPending: ([String]) -> Void
    private var generation = 0
    private(set) var enabled: Bool
    private(set) var schedule: ShortcutBridgeSchedule
    private(set) var isWorking = false
    private(set) var message: String?

    init(defaults: UserDefaults = .standard,
         status: @escaping () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         },
         authorize: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
         },
         add: @escaping (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         },
         remove: @escaping ([String]) -> Void = {
             let center = UNUserNotificationCenter.current()
             center.removePendingNotificationRequests(withIdentifiers: $0)
             center.removeDeliveredNotifications(withIdentifiers: $0)
         },
         cancelPending: @escaping ([String]) -> Void = {
             UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0)
         }) {
        self.defaults = defaults
        self.status = status
        self.authorize = authorize
        self.add = add
        self.remove = remove
        self.cancelPending = cancelPending
        enabled = defaults.bool(forKey: Self.enabledKey)
        schedule = ShortcutBridgeSchedule(
            hour: defaults.object(forKey: Self.hourKey) as? Int ?? 9,
            minute: defaults.object(forKey: Self.minuteKey) as? Int ?? 0)
    }

    /// Called only by the app scene, never by the refresh intent or coordinator.
    /// Restores a single repeating request, without asking for permission.
    func restore() async {
        guard !isWorking else { return }
        guard enabled else { cancelPending([ShortcutBridgeSchedule.dailyID]); return }
        await deliver(test: false, mayPrompt: false)
    }

    func setEnabled(_ value: Bool) async {
        if !value {
            generation += 1
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            remove(ShortcutBridgeSchedule.identifiers)
            message = nil
            return
        }
        guard !isWorking else { return }
        await deliver(test: false, mayPrompt: true, enabling: true)
    }

    func setTime(_ date: Date, calendar: Calendar = .current) async {
        guard !isWorking else { return }
        schedule = ShortcutBridgeSchedule(hour: calendar.component(.hour, from: date),
                                          minute: calendar.component(.minute, from: date))
        defaults.set(schedule.hour, forKey: Self.hourKey)
        defaults.set(schedule.minute, forKey: Self.minuteKey)
        if enabled {
            // A failed edit must not leave the old hour armed behind the new preference.
            cancelPending([ShortcutBridgeSchedule.dailyID])
            await restore()
        }
    }

    var time: Date {
        Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute,
                              second: 0, of: Date()) ?? Date()
    }

    /// A test is an explicit permission gesture but does not enable the daily schedule.
    func test() async {
        guard !isWorking else { return }
        await deliver(test: true, mayPrompt: true)
    }

    static func accepts(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    private func deliver(test: Bool, mayPrompt: Bool, enabling: Bool = false) async {
        isWorking = true
        let token = generation
        defer { isWorking = false }
        do {
            let current = await status()
            guard token == generation else { return }
            var granted = Self.accepts(current)
            if current == .notDetermined && mayPrompt {
                granted = try await authorize()
            }
            guard token == generation else { return }
            guard granted else {
                if !test { cancelPending([ShortcutBridgeSchedule.dailyID]) }
                message = "El puente necesita notificaciones. Permítelas en Ajustes del sistema → PriceTracker → Notificaciones y vuelve a activar o probar."
                return
            }
            try await add(schedule.request(test: test))
            guard token == generation else {
                remove(ShortcutBridgeSchedule.identifiers)
                return
            }
            if enabling {
                enabled = true
                defaults.set(true, forKey: Self.enabledKey)
            }
            message = test
                ? "Prueba programada para dentro de 5 segundos. Sal de la app para comprobar la entrega. Solo ejecutará la acción si has configurado una automatización compatible."
                : nil
        } catch {
            guard token == generation else { return }
            message = "No se pudo programar el puente: \(error.localizedDescription)"
        }
    }
}
