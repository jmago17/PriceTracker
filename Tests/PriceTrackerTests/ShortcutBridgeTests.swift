import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import PriceTracker

@MainActor
private final class BridgeProbe {
    let defaults: UserDefaults
    let suite: String
    var authorization: UNAuthorizationStatus = .authorized
    var granted = true
    var prompts = 0
    var requests: [UNNotificationRequest] = []
    var removed: [[String]] = []
    var cancelled: [[String]] = []
    var failAdd = false
    var suspendAdd = false
    var suspendStatus = false
    var failAuthorization = false
    var statusRead: CheckedContinuation<Void, Never>?
    var addition: CheckedContinuation<Void, Never>?

    init() {
        let name = "ShortcutBridgeTests.\(UUID().uuidString)"
        suite = name
        defaults = UserDefaults(suiteName: name)!
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    func settings() -> ShortcutBridgeSettings {
        ShortcutBridgeSettings(defaults: defaults, status: {
            if self.suspendStatus {
                await withCheckedContinuation { self.statusRead = $0 }
            }
            return self.authorization
        }, authorize: {
            self.prompts += 1
            if self.failAuthorization { throw CocoaError(.userCancelled) }
            return self.granted
        },
            add: { request in
                if self.failAdd { throw CocoaError(.fileWriteUnknown) }
                if self.suspendAdd {
                    await withCheckedContinuation { self.addition = $0 }
                }
                self.requests.append(request)
            }, remove: { self.removed.append($0) },
            cancelPending: { self.cancelled.append($0) })
    }
}

@Suite("Shortcut notification bridge")
@MainActor
struct ShortcutBridgeTests {
    @Test func calendarAndSilentContent() throws {
        let schedule = ShortcutBridgeSchedule(hour: 23, minute: 59)
        let request = schedule.request()
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents == DateComponents(hour: 23, minute: 59))
        #expect(request.identifier == ShortcutBridgeSchedule.dailyID)
        #expect(request.content.title == "PriceTracker.bridge")
        #expect(request.content.body == "PriceTracker refresh")
        #expect(request.content.sound == nil)
        #expect(request.content.badge == nil)
        #expect(request.content.interruptionLevel == .passive)
        let test = schedule.request(test: true)
        let timer = try #require(test.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(!timer.repeats && timer.timeInterval == 5)
        #expect(test.identifier == ShortcutBridgeSchedule.testID)
        #expect(ShortcutBridgeSchedule(hour: -1, minute: 60) == ShortcutBridgeSchedule())
    }

    @Test func restoringNeverPromptsAndPreservesDeliveredTest() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.authorization = .notDetermined
        let disabled = p.settings()
        await disabled.restore()
        #expect(p.prompts == 0 && p.requests.isEmpty && p.removed.isEmpty)
        #expect(p.cancelled == [[ShortcutBridgeSchedule.dailyID]])
        p.defaults.set(true, forKey: ShortcutBridgeSettings.enabledKey)
        let enabled = p.settings()
        await enabled.restore()
        #expect(p.prompts == 0 && p.requests.isEmpty && p.removed.isEmpty)
        #expect(enabled.enabled && enabled.message != nil)
    }

    @Test func explicitEnableDenialAndRetry() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.authorization = .notDetermined; p.granted = false
        let settings = p.settings()
        await settings.setEnabled(true)
        #expect(p.prompts == 1 && !settings.enabled && settings.message != nil)
        p.authorization = .denied
        await settings.test()
        #expect(p.prompts == 1 && p.requests.isEmpty)
        p.authorization = .authorized
        await settings.setEnabled(true)
        #expect(settings.enabled && settings.message == nil)
        #expect(p.defaults.bool(forKey: ShortcutBridgeSettings.enabledKey))
        #expect(p.requests.count == 1)
    }

    @Test func testPermissionDoesNotOptInOrAlterPriceAlerts() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.authorization = .notDetermined
        p.defaults.set(true, forKey: "notifyPriceChanges")
        let settings = p.settings()
        await settings.test()
        #expect(p.prompts == 1 && !settings.enabled)
        #expect(p.requests.map(\.identifier) == [ShortcutBridgeSchedule.testID])
        await settings.setEnabled(false)
        #expect(p.removed == [ShortcutBridgeSchedule.identifiers])
        #expect(p.defaults.bool(forKey: "notifyPriceChanges"))
    }

    @Test func persistedTimeAndRepeatedRestoreUseSingleDailyID() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        let settings = p.settings()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 17, minute: 42))!
        await settings.setTime(date, calendar: calendar)
        #expect(p.requests.isEmpty)
        await settings.setEnabled(true)
        let restored = p.settings()
        await restored.restore()
        #expect(restored.schedule == ShortcutBridgeSchedule(hour: 17, minute: 42))
        #expect(p.requests.count == 2)
        #expect(Set(p.requests.map(\.identifier)) == [ShortcutBridgeSchedule.dailyID])
        #expect(p.removed.isEmpty && p.cancelled.isEmpty)
    }

    @Test func schedulingErrorDoesNotOptIn() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.failAdd = true
        let settings = p.settings()
        await settings.setEnabled(true)
        #expect(!settings.enabled && !settings.isWorking && settings.message != nil)
        #expect(!p.defaults.bool(forKey: ShortcutBridgeSettings.enabledKey))
    }

    @Test func disableDuringAddCannotResurrectRequest() async throws {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.suspendAdd = true
        let settings = p.settings()
        let enabling = Task { await settings.setEnabled(true) }
        for _ in 0..<100 where p.addition == nil { await Task.yield() }
        let continuation = try #require(p.addition)
        #expect(settings.isWorking)
        // Time edits are locked while an OS request is outstanding, in model and UI.
        let original = settings.schedule
        await settings.setTime(Date())
        #expect(settings.schedule == original)
        await settings.setEnabled(false)
        continuation.resume()
        await enabling.value
        #expect(!settings.enabled && !settings.isWorking)
        #expect(!p.defaults.bool(forKey: ShortcutBridgeSettings.enabledKey))
        #expect(p.removed == [ShortcutBridgeSchedule.identifiers, ShortcutBridgeSchedule.identifiers])
    }

    @Test func authorizationErrorIsVisible() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.authorization = .notDetermined; p.failAuthorization = true
        let settings = p.settings()
        await settings.test()
        #expect(settings.message != nil && !settings.isWorking)
        #expect(p.requests.isEmpty && !settings.enabled)
    }

    @Test func disableDuringStatusDoesNotPrompt() async throws {
        let p = BridgeProbe(); defer { p.cleanup() }
        p.authorization = .notDetermined; p.suspendStatus = true
        let settings = p.settings()
        let enabling = Task { await settings.setEnabled(true) }
        for _ in 0..<100 where p.statusRead == nil { await Task.yield() }
        let continuation = try #require(p.statusRead)
        await settings.setEnabled(false)
        continuation.resume()
        await enabling.value
        #expect(p.prompts == 0 && p.requests.isEmpty && !settings.enabled)
    }

    @Test func failedTimeEditCancelsOldHourButPreservesDelivered() async {
        let p = BridgeProbe(); defer { p.cleanup() }
        let settings = p.settings()
        await settings.setEnabled(true)
        p.failAdd = true
        await settings.setTime(Date())
        #expect(p.cancelled == [[ShortcutBridgeSchedule.dailyID]])
        #expect(p.removed.isEmpty && settings.message != nil)
        #expect(settings.enabled)
    }

    @Test func acceptedPermissions() {
        #expect(ShortcutBridgeSettings.accepts(.authorized))
        #expect(ShortcutBridgeSettings.accepts(.provisional))
        #expect(ShortcutBridgeSettings.accepts(.ephemeral))
        #expect(!ShortcutBridgeSettings.accepts(.denied))
        #expect(!ShortcutBridgeSettings.accepts(.notDetermined))
    }
}
