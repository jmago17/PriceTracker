import Foundation
import Testing
@testable import PriceTracker

// No network and no real key: a fake transport, an in-memory key store and a
// throwaway App Group suite for the inbox.

private func makeInbox() -> SharedURLInbox {
    let suite = "share-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return SharedURLInbox(defaults: defaults)
}

private func makeSubmission(
    transport: FakeTransport,
    key: String? = testKey,
    inbox: SharedURLInbox = makeInbox()
) -> ShareSubmission {
    let settings = PriceBucketSettings(
        defaults: UserDefaults(suiteName: "share-settings-\(UUID().uuidString)")!,
        keyStore: MemoryKeyStore(key)
    )
    return ShareSubmission(settings: settings, transport: transport, inbox: inbox)
}

private let sharedURL = URL(string: "https://tienda.example/zapatillas")!

private func body(_ request: URLRequest) -> [String: Any] {
    (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

struct ShareSubmissionTests {
    @Test func successSendsSizeThenPatchesTheMinimumPriceInCents() async throws {
        let id = UUID()
        let item = itemJSON(id: id)
        let transport = FakeTransport { _ in (200, "{\"ok\":true,\"item\":\(item)}") }
        let inbox = makeInbox()
        let outcome = try await makeSubmission(transport: transport, inbox: inbox)
            .submit(url: sharedURL, minimumPriceText: "49,99", sizeText: " 42 ")

        #expect(outcome == .added(targetFailed: false))
        #expect(outcome.message == "Añadido a tu lista")
        #expect(inbox.load().isEmpty)
        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["POST /api/v1/items", "PATCH /api/v1/items/\(id.uuidString)"])
        #expect(body(requests[0])["url"] as? String == sharedURL.absoluteString)
        #expect(body(requests[0])["size"] as? String == "42")
        #expect(body(requests[1])["targetPriceCents"] as? Int == 4_999)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-key") == testKey })
    }

    @Test func noPriceAndEmptySizeSendOnlyTheLink() async throws {
        let item = itemJSON()
        let transport = FakeTransport { _ in (200, "{\"ok\":true,\"item\":\(item)}") }
        let outcome = try await makeSubmission(transport: transport)
            .submit(url: sharedURL, minimumPriceText: "  ", sizeText: "   ")

        #expect(outcome == .added(targetFailed: false))
        #expect(transport.requests.count == 1)
        #expect(body(transport.requests[0])["size"] == nil)
    }

    @Test func existingItemCountsAsSuccess() async throws {
        let transport = FakeTransport { _ in (422, "{\"ok\":false,\"error\":\"Ese enlace ya existe en el catálogo\"}") }
        let inbox = makeInbox()
        let outcome = try await makeSubmission(transport: transport, inbox: inbox)
            .submit(url: sharedURL, minimumPriceText: "10", sizeText: "")

        #expect(outcome == .alreadyExists)
        #expect(outcome.message == "Ya estaba en tu lista")
        #expect(inbox.load().isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test func missingKeyParksTheLinkInTheInboxWithoutCallingTheServer() async throws {
        let transport = FakeTransport()
        let inbox = makeInbox()
        let outcome = try await makeSubmission(transport: transport, key: nil, inbox: inbox)
            .submit(url: sharedURL, minimumPriceText: "49,99", sizeText: "M")

        #expect(outcome == .queued(.notConfigured))
        #expect(outcome.message == "Guardado, se enviará al abrir la app")
        #expect(transport.requests.isEmpty)
        let entry = try #require(inbox.load().first)
        #expect(entry.urlString == sharedURL.absoluteString)
        #expect(entry.size == "M" && entry.targetPriceCents == 4_999)
    }

    @Test func networkErrorParksTheLinkInTheInbox() async throws {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let inbox = makeInbox()
        let outcome = try await makeSubmission(transport: transport, inbox: inbox)
            .submit(url: sharedURL, minimumPriceText: "", sizeText: "")

        #expect(outcome == .queued(.offline))
        #expect(inbox.load().map(\.urlString) == [sharedURL.absoluteString])
    }

    @Test func serverAndKeyErrorsAreReportedNotQueued() async throws {
        let inbox = makeInbox()
        let rejected = FakeTransport { _ in (401, "{}") }
        await #expect(throws: PriceBucketError.unauthorized) {
            try await makeSubmission(transport: rejected, inbox: inbox).submit(url: sharedURL)
        }
        let broken = FakeTransport { _ in (500, "{}") }
        await #expect(throws: PriceBucketError.server(500)) {
            try await makeSubmission(transport: broken, inbox: inbox).submit(url: sharedURL)
        }
        #expect(inbox.load().isEmpty)
    }

    @Test func failedPriceUpdateStillCountsAsAddedAndSaysSo() async throws {
        let item = itemJSON()
        let transport = FakeTransport { request in
            request.httpMethod == "PATCH" ? (500, "{}") : (200, "{\"ok\":true,\"item\":\(item)}")
        }
        let outcome = try await makeSubmission(transport: transport)
            .submit(url: sharedURL, minimumPriceText: "20", sizeText: "")

        #expect(outcome == .added(targetFailed: true))
        #expect(outcome.message.contains("precio mínimo"))
    }

    @Test func invalidInputIsRejectedBeforeAnyRequest() async throws {
        let transport = FakeTransport()
        let submission = makeSubmission(transport: transport)
        await #expect(throws: PriceBucketError.self) {
            try await submission.submit(url: sharedURL, minimumPriceText: "barato")
        }
        await #expect(throws: PriceBucketError.self) {
            try await submission.submit(url: URL(string: "ftp://tienda.example/x")!)
        }
        #expect(transport.requests.isEmpty)
    }
}

struct PriceInputTests {
    @Test(arguments: [
        ("12,50", 1_250), ("12.5", 1_250), ("49", 4_900), ("0,99", 99), (" 7.05 € ", 705),
        ("1.234,56", 123_456), ("1,234.56", 123_456), ("1.234", 123_400), ("1.234.567", 123_456_700),
    ])
    func parsesCommaAndPointDecimals(text: String, cents: Int) throws {
        #expect(try PriceInput.cents(from: text) == cents)
    }

    @Test func emptyTextMeansNoPrice() throws {
        #expect(try PriceInput.cents(from: "") == nil)
        #expect(try PriceInput.cents(from: "   ") == nil)
    }

    @Test(arguments: ["abc", "0", "0,00", "-5", "1234,567", "1e3", "12,5x"])
    func rejectsNonPositiveOrMalformedAmounts(text: String) {
        #expect(throws: PriceBucketError.self) { try PriceInput.cents(from: text) }
    }
}

// MARK: - Shared storage migration

struct PriceBucketStorageMigrationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "migration-tests-\(UUID().uuidString)")!
    }

    @Test func keyOnlyInTheUngroupedStoreIsCopiedToTheSharedOne() throws {
        let shared = MemoryKeyStore(), legacy = MemoryKeyStore("legacy-key-not-a-secret")
        let settings = PriceBucketSettings(defaults: defaults(), keyStore: shared, legacyKeyStore: legacy)
        settings.migrateLegacyStorage()

        #expect(try shared.read() == "legacy-key-not-a-secret")
        #expect(settings.isConfigured)
    }

    @Test func anExistingSharedKeyIsNeverOverwritten() throws {
        let shared = MemoryKeyStore("current-key-not-a-secret"), legacy = MemoryKeyStore("legacy-key-not-a-secret")
        let settings = PriceBucketSettings(defaults: defaults(), keyStore: shared, legacyKeyStore: legacy)
        settings.migrateLegacyStorage()

        #expect(try shared.read() == "current-key-not-a-secret")
    }

    @Test func nothingToMigrateLeavesTheAppUnconfigured() {
        let settings = PriceBucketSettings(defaults: defaults(), keyStore: MemoryKeyStore(), legacyKeyStore: MemoryKeyStore())
        settings.migrateLegacyStorage()
        #expect(!settings.isConfigured)
    }

    @Test func serverURLMovesFromStandardDefaultsToTheAppGroup() {
        let group = defaults(), legacy = defaults()
        legacy.set("https://servidor.example", forKey: PriceBucketSettings.baseURLDefaultsKey)
        let settings = PriceBucketSettings(defaults: group, keyStore: MemoryKeyStore(), legacyDefaults: legacy)
        settings.migrateLegacyStorage()

        #expect(settings.baseURL.absoluteString == "https://servidor.example")
        #expect(group.string(forKey: PriceBucketSettings.baseURLDefaultsKey) == "https://servidor.example")
        #expect(legacy.object(forKey: PriceBucketSettings.baseURLDefaultsKey) == nil)
    }

    @Test func aURLAlreadyInTheAppGroupWinsOverTheLegacyOne() {
        let group = defaults(), legacy = defaults()
        group.set("https://nuevo.example", forKey: PriceBucketSettings.baseURLDefaultsKey)
        legacy.set("https://viejo.example", forKey: PriceBucketSettings.baseURLDefaultsKey)
        let settings = PriceBucketSettings(defaults: group, keyStore: MemoryKeyStore(), legacyDefaults: legacy)
        settings.migrateLegacyStorage()

        #expect(settings.baseURL.absoluteString == "https://nuevo.example")
        #expect(legacy.object(forKey: PriceBucketSettings.baseURLDefaultsKey) == nil)
    }

    #if os(iOS)
    // iOS only: the macOS host runner has no unlocked login keychain to write to.
    @Test func keychainStoreRoundTripsWithAndWithoutTheGroupEntitlement() throws {
        // Throwaway service name: never touches the real key. Whether the host is
        // entitled for the shared group or not (errSecMissingEntitlement), the
        // store must keep working.
        let store = KeychainKeyStore(service: "com.maromeapps.PriceTracker.tests.\(UUID().uuidString)")
        defer { try? store.write(nil) }
        #expect(try store.read() == nil)
        try store.write("first-not-a-secret")
        #expect(try store.read() == "first-not-a-secret")
        try store.write("second-not-a-secret")
        #expect(try store.read() == "second-not-a-secret")
        try store.write(nil)
        #expect(try store.read() == nil)
    }
    #endif
}
