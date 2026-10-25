import AppIntents
import Foundation
import Testing
@testable import PriceTracker

private actor MemoryCatalog: PriceHistoryStoring {
    var items: [Item]
    var history: [PriceObservation] = []
    init(_ items: [Item]) { self.items = items }
    func loadAll() -> [Item] { items }
    func save(_ items: [Item]) { self.items = items }
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item {
        let stored = try await upsert(item)
        history.append(observation)
        return stored
    }
    func observations(for identityKey: String) -> [PriceObservation] { history }
}

private actor RecordingConnector: StoreConnector {
    nonisolated let store: Store = .appStore
    var calls = 0
    var regions: [String] = []
    let price: Int
    let fails: Bool
    init(price: Int, fails: Bool = false) { self.price = price; self.fails = fails }
    nonisolated func canResolve(url: URL) -> Bool { false }
    func resolve(url: URL) async throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) async throws -> FetchResult {
        calls += 1
        regions.append(item.region)
        await Task.yield()
        if fails { throw ConnectorError.network("offline") }
        return FetchResult(priceCents: price, currency: item.currency, isOnSale: false, availability: "available")
    }
}

private actor DeliveryLog {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

private func automationItem(_ id: String = "1", price: Int = 1000) -> Item {
    Item(store: .appStore, storeItemID: id, region: "FR", currency: "EUR",
         canonicalURL: URL(string: "https://apps.apple.com/fr/app/id\(id)")!, title: "Item \(id)",
         priceCurrentCents: price, priceAtAddCents: 2000, priceReferenceCents: 2500, priceLowCents: price)
}
private func alerts() -> JSONFileAlertStore {
    JSONFileAlertStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("alerts-\(UUID()).json"))
}

struct AutomationTests {
    @Test func equalPriceRecordsSuccessWithoutChangeOrNotification() async throws {
        var item = automationItem()
        item.targetPriceCents = 1200 // Equal price must not create a first target alert either.
        let store = MemoryCatalog([item]), log = alerts()
        let connector = RecordingConnector(price: 1000)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        let result = await coordinator.refreshResult(id: item.id)
        #expect(result.error == nil && !result.changed)
        #expect(result.priceCents == 1000 && result.currency == "EUR")
        #expect(result.checkedAt != nil)
        #expect(await store.history.count == 1)
        #expect(try await log.loadAll().isEmpty)
        let stored = try #require(try await store.item(id: item.id))
        #expect(stored.priceReferenceCents == 2500 && stored.priceAtAddCents == 2000)
        #expect(await connector.regions == ["FR"])
    }

    @Test func overlappingRefreshesDoNotDuplicateChangeAlerts() async throws {
        let item = automationItem(), log = alerts()
        let store = MemoryCatalog([item]), connector = RecordingConnector(price: 500)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        async let first = coordinator.refreshResult(id: item.id)
        async let second = coordinator.refreshResult(id: item.id)
        let results = await [first, second]
        #expect(results.filter(\.changed).count == 1)
        #expect(await store.history.count == 2)
        #expect(try await log.loadAll().filter { $0.kind == .drop }.count == 1)
    }

    @Test func errorAndDeletedItemReturnValuesAndLoopContinues() async throws {
        let first = automationItem(), second = automationItem("2")
        let store = MemoryCatalog([first, second]), connector = RecordingConnector(price: 500, fails: true)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: alerts(), connectorToFetch: { _ in connector })
        let missing = await coordinator.refreshResult(id: UUID())
        let failed = await coordinator.refreshResult(id: first.id)
        let summary = try await coordinator.refreshCatalog()
        #expect(missing.error != nil && failed.error != nil && !failed.changed)
        #expect(failed.priceCents == 1000)
        #expect(summary.checked == 2 && summary.failed == 2)
        #expect(await store.history.isEmpty)
    }

    @Test func queryResolvesPersistentIDsInRequestedOrderAndFilters() async throws {
        let first = automationItem(), second = automationItem("2")
        let store = MemoryCatalog([first, second])
        let query = ItemQuery(store: store)
        let found = try await query.entities(for: [second.id, UUID(), first.id])
        #expect(found.map(\.id) == [second.id, first.id])
        let filtered = try await query.entities(matching: [{ $0.storeItemID == "2" }], mode: .and, sortedBy: [], limit: 1)
        #expect(filtered.map(\.id) == [second.id])
        #expect(try await query.entities(matching: [], mode: .and, sortedBy: [], limit: 0).isEmpty)
        #expect(ItemFilterEngine.limit([first], to: -1).isEmpty)
        let free = ItemEntity(item: automationItem(price: 0))
        #expect(free.priceCurrentCents == 0)
        var unknown = first; unknown.priceCurrentCents = nil
        #expect(ItemEntity(item: unknown).priceCurrentCents == nil)
    }

    @Test func notifierDeduplicatesConcurrentDeliveryAndHonorsOptOut() async throws {
        let item = automationItem(), log = alerts(), sink = DeliveryLog()
        let store = MemoryCatalog([item])
        try await log.append(PriceAlert(itemID: item.id, kind: .drop, priceFromCents: 1000, priceToCents: 500))
        let disabled = AlertNotifier(alertStore: log, itemStore: store, enabled: { false }, authorized: { true }, deliver: { id, _, _, _ in await sink.add(id) })
        #expect(try await disabled.notifyPendingDrops() == 0)
        let denied = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, authorized: { false }, deliver: { id, _, _, _ in await sink.add(id) })
        #expect(try await denied.notifyPendingDrops() == 0)
        let notifier = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, authorized: { true }, deliver: { id, _, _, _ in await sink.add(id); await Task.yield() })
        async let a = notifier.notifyPendingDrops()
        async let b = notifier.notifyPendingDrops()
        let counts = try await [a, b]
        #expect(counts.reduce(0, +) == 1)
        #expect(await sink.ids.count == 1)
        #expect(try await log.pendingAlerts().isEmpty)
    }

    @Test @MainActor func permissionsOnlyRequestedOnExplicitOptInAndSchedulingCancels() async {
        let defaults = UserDefaults(suiteName: "automation-tests-\(UUID())")!
        var requests = 0, cancels = 0
        var submitted: [Date] = []
        let settings = DailyRefreshSettings(defaults: defaults, submit: { submitted.append($0) }, cancel: { cancels += 1 }, authorize: { requests += 1; return false }, prepareNotifications: {})
        #expect(requests == 0 && submitted.isEmpty)
        settings.setDailyEnabled(true)
        #expect(requests == 0 && submitted.count == 1)
        let first = submitted[0]
        settings.schedule()
        #expect(submitted.last == first)
        await settings.setNotificationsEnabled(true)
        #expect(requests == 1 && !settings.notificationsEnabled)
        await settings.setNotificationsEnabled(false)
        #expect(requests == 1)
        settings.setDailyEnabled(false)
        #expect(cancels == 1 && !settings.dailyEnabled)
        let enabled = DailyRefreshSettings(defaults: defaults, submit: { _ in }, cancel: {}, authorize: { true }, prepareNotifications: {})
        await enabled.setNotificationsEnabled(true)
        #expect(enabled.notificationsEnabled && defaults.bool(forKey: "notifyPriceChanges"))
    }
}

private actor CancellationProbe {
    var started = false
    var cancelled = false
    var waiter: CheckedContinuation<Void, Never>?
    func waitForStart() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func work() async {
        started = true
        waiter?.resume(); waiter = nil
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true }
    }
}

extension AutomationTests {
    @Test func savedEntityIDSurvivesReopenAndDuplicateImport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).sqlite")
        let store = SQLiteItemStore(databaseURL: url)
        let original = automationItem()
        try await store.upsert(original)
        var duplicate = original; duplicate.id = UUID(); duplicate.title = "Renamed"
        let stored = try await store.upsert(duplicate)
        #expect(stored.id == original.id)
        let query = ItemQuery(store: SQLiteItemStore(databaseURL: url))
        let restored = try await query.entities(for: [original.id])
        #expect(restored.first?.id == original.id && restored.first?.title == "Renamed")
    }

    @Test @MainActor func disableCancelsRunningRefreshAndScheduleErrorsAreVisible() async {
        let defaults = UserDefaults(suiteName: "cancel-tests-\(UUID())")!
        let probe = CancellationProbe()
        let settings = DailyRefreshSettings(defaults: defaults, submit: { _ in }, cancel: {}, authorize: { false }, refresh: { await probe.work() }, prepareNotifications: {})
        settings.setDailyEnabled(true)
        let running = Task { await settings.run() }
        await probe.waitForStart()
        settings.setDailyEnabled(false)
        await running.value
        #expect(await probe.cancelled)
        let broken = DailyRefreshSettings(defaults: defaults, submit: { _ in throw ConnectorError.network("scheduler unavailable") }, cancel: {}, authorize: { throw ConnectorError.network("permission failed") }, prepareNotifications: {})
        broken.setDailyEnabled(true)
        #expect(broken.message?.contains("programar") == true)
        await broken.setNotificationsEnabled(true)
        #expect(!broken.notificationsEnabled && !broken.requestingPermission)
    }

    @Test @MainActor func systemExpirationCancelsWorker() async {
        let defaults = UserDefaults(suiteName: "expiration-tests-\(UUID())")!
        let probe = CancellationProbe()
        let settings = DailyRefreshSettings(defaults: defaults, submit: { _ in }, cancel: {}, authorize: { false }, refresh: { await probe.work() }, prepareNotifications: {})
        settings.setDailyEnabled(true)
        let running = Task { await settings.run() }
        await probe.waitForStart()
        running.cancel()
        await running.value
        #expect(await probe.cancelled)
    }

    @Test @MainActor func siriSearchPassesTermToForegroundRoute() async throws {
        var intent = SearchCatalogIntent()
        intent.criteria = StringSearchCriteria(term: "Hades")
        _ = try await intent.perform()
        #expect(CatalogSearchNavigation.shared.pending?.term == "Hades")
        CatalogSearchNavigation.shared.pending = nil
    }
}

private struct CancellationConnector: StoreConnector {
    let store: Store = .appStore
    let probe: CancellationProbe
    func canResolve(url: URL) -> Bool { false }
    func resolve(url: URL) async throws -> ResolvedItem { throw ConnectorError.unrecognizedURL }
    func fetch(_ item: Item) async throws -> FetchResult {
        await probe.work()
        return FetchResult(priceCents: 500, currency: "EUR", isOnSale: false, availability: "available")
    }
}

extension AutomationTests {
    @Test func priceRiseIsAChangeButNotADropAndUnknownFirstPriceDoesNotAlert() async throws {
        let item = automationItem(), store = MemoryCatalog([automationItem()])
        // Use the same persistent item instance for the coordinator lookup.
        try await store.save([item])
        let log = alerts(), connector = RecordingConnector(price: 2500)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        let result = await coordinator.refreshResult(id: item.id)
        #expect(result.changed && !result.dropped && result.error == nil)
        #expect(try await log.loadAll().map(\.kind) == [.priceChange])
        var unknown = item; unknown.priceCurrentCents = nil; unknown.priceLowCents = nil; unknown.targetPriceCents = 3000
        let evaluation = PriceDropDetector.evaluate(item: unknown, fetch: FetchResult(priceCents: 1000, currency: "EUR", isOnSale: false, availability: "available"))
        #expect(evaluation.alerts.isEmpty)
    }

    @Test func cancelledFetchDoesNotWriteHistoryOrRecordNetworkFailure() async throws {
        let item = automationItem(), probe = CancellationProbe()
        let store = MemoryCatalog([item]), log = alerts()
        let connector = CancellationConnector(probe: probe)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        let task = Task { await coordinator.refreshResult(id: item.id) }
        await probe.waitForStart()
        task.cancel()
        let result = await task.value
        #expect(result.error != nil)
        #expect(await store.history.isEmpty)
        #expect(try await store.item(id: item.id)?.consecutiveFailures == 0)
        #expect(try await log.loadAll().isEmpty)
    }

    @Test func concurrentAlertAppendsAreAtomic() async throws {
        let log = alerts(), itemID = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await log.append(PriceAlert(itemID: itemID, kind: .drop, priceFromCents: 1000, priceToCents: 500))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await log.loadAll().count == 20)
    }
}

extension AutomationTests {
    @Test func refreshCommitRejectsDeletedOrConcurrentlyEditedRows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-\(UUID()).sqlite")
        let store = SQLiteItemStore(databaseURL: url)
        let otherConnection = SQLiteItemStore(databaseURL: url)
        let item = automationItem()
        try await store.upsert(item)
        var updated = item; updated.priceCurrentCents = 500
        let observation = PriceObservation(itemID: item.id, checkedAt: Date(), priceCents: 500,
                                           currency: "EUR", isOnSale: false)
        var edited = item; edited.notes = "Keep this concurrent edit"
        try await otherConnection.upsert(edited)
        await #expect(throws: RefreshCommitError.self) {
            try await store.commitRefresh(updated, expected: item, observation: observation)
        }
        #expect(try await store.item(id: item.id)?.notes == edited.notes)
        #expect(try await store.observations(for: item.identityKey).isEmpty)
        try await otherConnection.delete(id: item.id)
        await #expect(throws: RefreshCommitError.self) {
            try await store.commitRefresh(updated, expected: edited, observation: observation)
        }
        #expect(try await store.item(id: item.id) == nil)
        #expect(try await ItemQuery(store: store).entities(for: [item.id]).isEmpty)
        let connector = RecordingConnector(price: 500)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: alerts(), connectorToFetch: { _ in connector })
        let outcome = await coordinator.refreshResult(id: item.id)
        let result = RefreshResultEntity(outcome: outcome)
        #expect(!result.success && result.error != nil && !result.changed)
        #expect(result.itemID == item.id.uuidString)
        #expect(await connector.calls == 0)
    }
}

extension AutomationTests {
    @Test func sharedRefreshRoutesPersistRiseDedupAndResetWithoutHistoryPoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.sqlite")
        let store = SQLiteItemStore(databaseURL: url)
        let item = automationItem()
        try await store.upsert(item)
        let log = alerts(), connector = RecordingConnector(price: 2500)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        _ = await coordinator.refreshResult(id: item.id)
        let reopened = SQLiteItemStore(databaseURL: url)
        let restarted = RefreshCoordinator(itemStore: reopened, alertStore: log, connectorToFetch: { _ in connector })
        _ = try await restarted.refreshCatalog()
        #expect(try await log.loadAll().filter { $0.kind == .priceChange }.count == 1)
        let saved = try #require(try await reopened.item(id: item.id))
        var reset = saved
        let didReset1 = reset.useCurrentPriceAsInitial()
        #expect(didReset1)
        try await reopened.commitRefresh(reset, expected: saved, observation: nil)
        #expect(try await reopened.observations(for: item.identityKey).count == 2)
        _ = await restarted.refreshResult(id: item.id)
        #expect(try await log.loadAll().filter { $0.kind == .priceChange }.count == 1)
    }
}

extension AutomationTests {
    @Test func resetDiscardsPendingRiseAndInvalidFetchDoesNotAddHistory() async throws {
        let item = automationItem(), store = MemoryCatalog([automationItem()])
        try await store.save([item])
        let log = alerts(), sink = DeliveryLog(), connector = RecordingConnector(price: 2500)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in connector })
        _ = await coordinator.refreshResult(id: item.id)
        var saved = try #require(try await store.item(id: item.id))
        saved.useCurrentPriceAsInitial()
        try await store.upsert(saved)
        let notifier = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, authorized: { true },
                                     deliver: { id, _, _, _ in await sink.add(id) })
        #expect(try await notifier.notifyPendingDrops() == 0)
        #expect(await sink.ids.isEmpty)
        let invalid = RecordingConnector(price: -1)
        let invalidCoordinator = RefreshCoordinator(itemStore: store, alertStore: log, connectorToFetch: { _ in invalid })
        let outcome = await invalidCoordinator.refreshResult(id: item.id)
        #expect(outcome.error != nil)
        #expect(try await store.item(id: item.id)?.priceCurrentCents == 2500)
    }
}

private actor PriorityDeliveryLog {
    var levels: [Bool] = []
    func add(_ level: Bool) { levels.append(level) }
}

extension AutomationTests {
    @Test func highPriorityDealDoesNotElevateOtherItemsAndDeliveryDoesNotRepeat() async throws {
        let end = Date(timeIntervalSinceReferenceDate: 1_234_567_890.1234567)
        var high = automationItem("high", price: 500)
        high.priority = .high; high.onSaleUntil = end
        let normal = automationItem("normal", price: 500)
        let store = MemoryCatalog([high, normal]), log = alerts(), sink = PriorityDeliveryLog()
        try await log.append(PriceAlert(itemID: high.id, kind: .drop, priceFromCents: 1000, priceToCents: 500, confirmedSaleEndsAt: end, currency: "EUR"))
        try await log.append(PriceAlert(itemID: normal.id, kind: .drop, priceFromCents: 1000, priceToCents: 500, currency: "EUR"))
        let notifier = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, timeSensitiveEnabled: { true }, authorized: { true },
                                     deliver: { _, _, _, level in await sink.add(level) })
        #expect(try await notifier.notifyPendingDrops() == 2)
        let deliveredLevels = await sink.levels
        #expect(deliveredLevels == [false, true])
        #expect(try await notifier.notifyPendingDrops() == 0)
        #expect(await sink.levels.count == 2)
    }
}

extension AutomationTests {
    @Test func pendingDealFallsBackToNormalAfterSaleIsDisconfirmed() async throws {
        let now = Date(), end = now.addingTimeInterval(3600)
        var item = automationItem(price: 2000)
        item.priority = .high
        var fetched = FetchResult(priceCents: 1500, currency: "EUR", isOnSale: true, saleEndsAt: end, availability: "available")
        let first = PriceDropDetector.evaluate(item: item, fetch: fetched, now: now)
        let draft = try #require(first.alerts.last)
        let log = alerts(), sink = PriorityDeliveryLog()
        try await log.append(PriceAlert(itemID: item.id, kind: draft.kind,
                                       priceFromCents: draft.fromCents, priceToCents: draft.toCents,
                                       confirmedSaleEndsAt: draft.confirmedSaleEndsAt, currency: "EUR"))
        fetched.isOnSale = false
        let next = PriceDropDetector.evaluate(item: first.updatedItem, fetch: fetched, now: now)
        let store = MemoryCatalog([next.updatedItem])
        let notifier = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, timeSensitiveEnabled: { true }, authorized: { true },
                                     deliver: { _, _, _, level in await sink.add(level) })
        #expect(try await notifier.notifyPendingDrops() == 1)
        let levels = await sink.levels
        #expect(levels == [false])
        #expect(try await notifier.notifyPendingDrops() == 0)
    }
}

// Durable outbox fault injection. All catalog/JSON files are unique temporary fixtures.
private enum OutboxFault: Error { case injected }

private actor FaultAlertSink: AlertStoring {
    let backing: JSONFileAlertStore
    var failOnAppend: Int?
    var failAfterWrite: Bool
    var calls = 0
    init(url: URL, failOnAppend: Int?, afterWrite: Bool = false) {
        backing = JSONFileAlertStore(fileURL: url); self.failOnAppend = failOnAppend; failAfterWrite = afterWrite
    }
    func loadAll() async throws -> [PriceAlert] { try await backing.loadAll() }
    func save(_ alerts: [PriceAlert]) async throws { try await backing.save(alerts) }
    func append(_ alert: PriceAlert) async throws -> PriceAlert {
        calls += 1
        let fail = calls == failOnAppend
        if fail && !failAfterWrite { throw OutboxFault.injected }
        let result = try await backing.append(alert)
        if fail { throw OutboxFault.injected }
        return result
    }
}

private actor FaultOutbox: AlertOutboxStoring {
    let backing: SQLiteItemStore
    var failAck: Bool
    init(_ backing: SQLiteItemStore, failAck: Bool) { self.backing = backing; self.failAck = failAck }
    func loadAll() async throws -> [Item] { try await backing.loadAll() }
    func save(_ items: [Item]) async throws { try await backing.save(items) }
    func upsert(_ item: Item, observation: PriceObservation) async throws -> Item { try await backing.upsert(item, observation: observation) }
    func observations(for identityKey: String) async throws -> [PriceObservation] { try await backing.observations(for: identityKey) }
    func commitRefresh(_ item: Item, expected: Item, observation: PriceObservation?, alerts: [PriceAlert]) async throws -> Item {
        try await backing.commitRefresh(item, expected: expected, observation: observation, alerts: alerts)
    }
    func pendingAlertDeliveries() async throws -> [PriceAlert] { try await backing.pendingAlertDeliveries() }
    func acknowledgeAlertDelivery(id: UUID) async throws {
        if failAck { failAck = false; throw OutboxFault.injected }
        try await backing.acknowledgeAlertDelivery(id: id)
    }
}

struct DurableAlertOutboxTests {
    private func fixtureItem() -> Item {
        var item = automationItem()
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        item.updatedAt = item.createdAt
        return item
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func eachAppendFailureAndCrashAfterWriteSurviveReopenAndEqualPriceRetry() async throws {
        for afterWrite in [false, true] {
            for failureIndex in [1, 2] {
                let directory = try directory()
                let db = directory.appendingPathComponent("catalog.sqlite")
                let json = directory.appendingPathComponent("alerts.json")
                let store = SQLiteItemStore(databaseURL: db)
                let item = fixtureItem()
                try await store.upsert(item)
                let sink = FaultAlertSink(url: json, failOnAppend: failureIndex, afterWrite: afterWrite)
                let connector = RecordingConnector(price: 500)
                let coordinator = RefreshCoordinator(itemStore: store, alertStore: sink, connectorToFetch: { _ in connector })
                let outcome = await coordinator.refreshResult(id: item.id)
                #expect(outcome.didPersist && outcome.error == nil && outcome.notificationError != nil)
                #expect(try await store.item(id: item.id)?.priceCurrentCents == 500)
                #expect(try await store.observations(for: item.identityKey).count == 1)
                #expect(try await store.pendingAlertDeliveries().count == 3 - failureIndex)
                let durableIDs = Set(try await store.pendingAlertDeliveries().map(\.id))
                let deliveredIDs = Set(try await sink.loadAll().map(\.id))
                // New store/coordinator/sink: no retained in-memory drafts.
                let reopened = SQLiteItemStore(databaseURL: db)
                let recoveredSink = JSONFileAlertStore(fileURL: json)
                let resumed = RefreshCoordinator(itemStore: reopened, alertStore: recoveredSink, connectorToFetch: { _ in connector })
                let equalPrice = await resumed.refreshResult(id: item.id)
                #expect(equalPrice.didPersist && !equalPrice.changed && equalPrice.notificationError == nil)
                let alerts = try await recoveredSink.loadAll()
                #expect(alerts.count == 2 && Set(alerts.map(\.id)).count == 2)
                #expect(Set(alerts.map(\.id)) == durableIDs.union(deliveredIDs))
                #expect(Set(alerts.map(\.kind)) == [.lowRecord, .drop])
                #expect(try await reopened.pendingAlertDeliveries().isEmpty)
                try await resumed.retryPendingAlerts()
                #expect(try await recoveredSink.loadAll().count == 2)
            }
        }
    }

    @Test func ackFailureRetriesStableIDsWithoutResettingSentAt() async throws {
        let dir = try directory(), item = fixtureItem()
        let store = SQLiteItemStore(databaseURL: dir.appendingPathComponent("catalog.sqlite"))
        try await store.upsert(item)
        let outbox = FaultOutbox(store, failAck: true)
        let json = dir.appendingPathComponent("alerts.json")
        let sink = JSONFileAlertStore(fileURL: json)
        let connector = RecordingConnector(price: 500)
        let coordinator = RefreshCoordinator(itemStore: outbox, alertStore: sink, connectorToFetch: { _ in connector })
        let outcome = await coordinator.refreshResult(id: item.id)
        #expect(outcome.didPersist && outcome.notificationError != nil)
        let appended = try #require(try await sink.loadAll().first)
        let sent = Date(timeIntervalSince1970: 1700000000)
        try await sink.markSent(ids: [appended.id], at: sent)
        try await coordinator.retryPendingAlerts()
        let recovered = try await sink.loadAll()
        #expect(recovered.count == 2)
        #expect(recovered.first(where: { $0.id == appended.id })?.sentAt == sent)
        #expect(try await store.pendingAlertDeliveries().isEmpty)
    }

    @Test func commitThenRestartBeforeDispatchDoesNotNeedAnotherFetch() async throws {
        let dir = try directory(), item = fixtureItem()
        let db = dir.appendingPathComponent("catalog.sqlite")
        let store = SQLiteItemStore(databaseURL: db)
        try await store.upsert(item)
        let evaluation = PriceDropDetector.evaluate(item: item, fetch: FetchResult(priceCents: 500, currency: "EUR", isOnSale: false, availability: "available"))
        let drafts = evaluation.alerts.map { PriceAlert(itemID: item.id, kind: $0.kind, priceFromCents: $0.fromCents, priceToCents: $0.toCents, currency: "EUR") }
        let point = PriceObservation(itemID: item.id, checkedAt: Date(), priceCents: 500, currency: "EUR", isOnSale: false)
        try await store.commitRefresh(evaluation.updatedItem, expected: item, observation: point, alerts: drafts)
        let reopened = SQLiteItemStore(databaseURL: db)
        let log = JSONFileAlertStore(fileURL: dir.appendingPathComponent("alerts.json"))
        let resumed = RefreshCoordinator(itemStore: reopened, alertStore: log, connectorToFetch: { _ in nil })
        try await resumed.retryPendingAlerts()
        #expect(Set(try await log.loadAll().map(\.id)) == Set(drafts.map(\.id)))
        #expect(try await reopened.observations(for: item.identityKey).count == 1)
        #expect(try await reopened.pendingAlertDeliveries().isEmpty)
    }

    @Test func deletedItemIsNotResurrectedByAnUndeliveredAlert() async throws {
        let dir = try directory(), item = fixtureItem()
        let store = SQLiteItemStore(databaseURL: dir.appendingPathComponent("catalog.sqlite"))
        try await store.upsert(item)
        let alert = PriceAlert(itemID: item.id, kind: .drop, priceFromCents: 1000, priceToCents: 500)
        try await store.commitRefresh(item, expected: item, observation: nil, alerts: [alert])
        try await store.delete(id: item.id)
        #expect(try await store.pendingAlertDeliveries().isEmpty)
        #expect(try await store.loadAll().isEmpty)
    }

    @Test func failedTransactionLeavesNoPriceObservationDedupeOrAlert() async throws {
        let dir = try directory(), item = fixtureItem()
        let store = SQLiteItemStore(databaseURL: dir.appendingPathComponent("catalog.sqlite"))
        try await store.upsert(item)
        var changed = item; changed.priceCurrentCents = 500; changed.lastAlertedPriceCents = 500
        let point = PriceObservation(itemID: item.id, checkedAt: Date(), priceCents: 500, currency: "EUR", isOnSale: false)
        // The second draft violates the transaction identity invariant AFTER
        // item, observation and first outbox row were written, forcing rollback.
        let first = PriceAlert(itemID: item.id, kind: .drop, priceFromCents: 1000, priceToCents: 500)
        let invalid = PriceAlert(itemID: UUID(), kind: .lowRecord, priceFromCents: 1000, priceToCents: 500)
        await #expect(throws: (any Error).self) {
            try await store.commitRefresh(changed, expected: item, observation: point, alerts: [first, invalid])
        }
        #expect(try await store.item(id: item.id) == item)
        #expect(try await store.observations(for: item.identityKey).isEmpty)
        #expect(try await store.pendingAlertDeliveries().isEmpty)
    }
}

struct OutboxProcessRecoveryTests {
    /// The host harness invokes this twice in SEPARATE swift-test processes.
    /// Phase one exits with append committed but no ack; phase two has no objects
    /// or draft state from the first process. Opt-in avoids persistent fixtures.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRICETRACKER_OUTBOX_PROCESS_FIXTURE"] != nil))
    func processBoundaryFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["PRICETRACKER_OUTBOX_PROCESS_FIXTURE"]))
        let store = SQLiteItemStore(databaseURL: directory.appendingPathComponent("catalog.sqlite"))
        let sink = JSONFileAlertStore(fileURL: directory.appendingPathComponent("alerts.json"))
        if environment["PRICETRACKER_OUTBOX_PROCESS_PHASE"] == "1" {
            var item = automationItem("process-boundary")
            item.createdAt = Date(timeIntervalSince1970: 1700000000); item.updatedAt = item.createdAt
            try await store.upsert(item)
            var updated = item; updated.priceCurrentCents = 500; updated.lastAlertedPriceCents = 500; updated.priceLowCents = 500
            let drafts = [AlertKind.lowRecord, .drop].map { PriceAlert(itemID: item.id, kind: $0, priceFromCents: 1000, priceToCents: 500, currency: "EUR") }
            let point = PriceObservation(itemID: item.id, checkedAt: item.createdAt, priceCents: 500, currency: "EUR", isOnSale: false)
            try await store.commitRefresh(updated, expected: item, observation: point, alerts: drafts)
            try await sink.append(drafts[0])
            try await sink.markSent(ids: [drafts[0].id], at: item.createdAt)
            #expect(try await store.pendingAlertDeliveries().count == 2)
        } else {
            let item = try #require(try await store.loadAll().first)
            let drafts = try await store.pendingAlertDeliveries()
            #expect(drafts.count == 2 && item.priceCurrentCents == 500 && item.lastAlertedPriceCents == 500)
            let connector = RecordingConnector(price: 500)
            let coordinator = RefreshCoordinator(itemStore: store, alertStore: sink, connectorToFetch: { _ in connector })
            try await coordinator.retryPendingAlerts()
            #expect(Set(try await sink.loadAll().map(\.id)) == Set(drafts.map(\.id)))
            #expect(try await sink.loadAll().filter { $0.sentAt != nil }.count == 1)
            #expect(try await store.pendingAlertDeliveries().isEmpty)
            let outcome = await coordinator.refreshResult(id: item.id)
            #expect(outcome.didPersist && !outcome.changed && outcome.notificationError == nil)
            #expect(try await sink.loadAll().count == 2)
            #expect(try await store.observations(for: item.identityKey).count == 2)
        }
    }
}

extension DurableAlertOutboxTests {
    @Test func independentSinksAndDispatchersDoNotLoseOrDuplicateDrafts() async throws {
        let dir = try directory(), item = fixtureItem()
        let db = dir.appendingPathComponent("catalog.sqlite"), json = dir.appendingPathComponent("alerts.json")
        let store = SQLiteItemStore(databaseURL: db)
        try await store.upsert(item)
        let drafts = (0..<24).map { _ in PriceAlert(itemID: item.id, kind: .drop, priceFromCents: 1000, priceToCents: 500) }
        try await store.commitRefresh(item, expected: item, observation: nil, alerts: drafts)
        let other = SQLiteItemStore(databaseURL: db)
        let firstSink = JSONFileAlertStore(fileURL: json), secondSink = JSONFileAlertStore(fileURL: json)
        async let first: Void = AlertOutboxDelivery.flush(itemStore: store, alertStore: firstSink)
        async let second: Void = AlertOutboxDelivery.flush(itemStore: other, alertStore: secondSink)
        _ = try await (first, second)
        let persisted = try await firstSink.loadAll()
        #expect(persisted.count == 24 && Set(persisted.map(\.id)) == Set(drafts.map(\.id)))
        #expect(try await store.pendingAlertDeliveries().isEmpty)
    }
}

extension DurableAlertOutboxTests {
    @Test func initialPriceRiseMarkerCannotConsumeAnUndeliveredAlert() async throws {
        let dir = try directory(), item = fixtureItem()
        let db = dir.appendingPathComponent("catalog.sqlite"), json = dir.appendingPathComponent("alerts.json")
        let store = SQLiteItemStore(databaseURL: db)
        try await store.upsert(item)
        let connector = RecordingConnector(price: 2500)
        let fault = FaultAlertSink(url: json, failOnAppend: 1)
        let coordinator = RefreshCoordinator(itemStore: store, alertStore: fault, connectorToFetch: { _ in connector })
        let failedDelivery = await coordinator.refreshResult(id: item.id)
        #expect(failedDelivery.didPersist && failedDelivery.notificationError != nil)
        let saved = try #require(try await store.item(id: item.id))
        #expect(saved.hasAlertedInitialPriceRise && saved.priceCurrentCents == 2500)
        #expect(try await store.pendingAlertDeliveries().count == 1)
        let reopened = SQLiteItemStore(databaseURL: db), sink = JSONFileAlertStore(fileURL: json)
        let resumed = RefreshCoordinator(itemStore: reopened, alertStore: sink, connectorToFetch: { _ in connector })
        let equalPrice = await resumed.refreshResult(id: item.id)
        let alerts = try await sink.loadAll()
        #expect(equalPrice.didPersist && !equalPrice.changed && equalPrice.notificationError == nil)
        #expect(alerts.count == 1 && alerts.first?.kind == .priceChange)
        #expect(alerts.first?.initialPriceAlertKey == saved.initialPriceAlertKey && alerts.first?.currency == "EUR")
        #expect(try await reopened.pendingAlertDeliveries().isEmpty)
    }
}
