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
        let disabled = AlertNotifier(alertStore: log, itemStore: store, enabled: { false }, authorized: { true }, deliver: { id, _, _ in await sink.add(id) })
        #expect(try await disabled.notifyPendingDrops() == 0)
        let denied = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, authorized: { false }, deliver: { id, _, _ in await sink.add(id) })
        #expect(try await denied.notifyPendingDrops() == 0)
        let notifier = AlertNotifier(alertStore: log, itemStore: store, enabled: { true }, authorized: { true }, deliver: { id, _, _ in await sink.add(id); await Task.yield() })
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
        let log = alerts(), connector = RecordingConnector(price: 1500)
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
