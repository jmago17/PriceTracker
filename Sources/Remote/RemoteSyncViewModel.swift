import Foundation
import Observation

/// State behind "Servidor PriceBucket" in Settings and the sync triggers
/// (launch, foreground, pull to refresh). A no-op in demo/test mode.
@MainActor
@Observable
final class RemoteSyncViewModel {
    private(set) var isConfigured = false
    private(set) var isSyncing = false
    private(set) var isTesting = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var connectionMessage: String?
    /// Bumped after a sync that reached the cache, so lists reload.
    private(set) var catalogRevision = 0

    var baseURLText = ""
    var apiKeyText = ""
    var settingsError: String?

    /// Foreground syncs closer than this to the previous attempt are skipped.
    static let minimumForegroundInterval: TimeInterval = 60

    private let environment: AppEnvironment
    private var lastAttempt: Date?

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var isAvailable: Bool { environment.remoteStore != nil }

    func load() async {
        isConfigured = environment.settings.isConfigured
        let url = environment.settings.baseURL
        baseURLText = url == PriceBucketSettings.defaultBaseURL ? "" : url.absoluteString
        lastSyncAt = await environment.remoteStore?.lastSyncDate()
    }

    /// Saves URL and (when typed) key. The key field is cleared once stored.
    func saveSettings() async {
        settingsError = nil
        do {
            try environment.settings.setBaseURL(baseURLText)
            if let key = apiKeyText.trimmedNonEmpty {
                try environment.settings.setAPIKey(key)
                apiKeyText = ""
            }
            connectionMessage = nil
            await load()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func removeKey() async {
        do {
            try environment.settings.setAPIKey(nil)
            connectionMessage = nil
            await load()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func testConnection() async {
        guard let remote = environment.remoteStore else { return }
        isTesting = true
        connectionMessage = nil
        defer { isTesting = false }
        do {
            let me = try await remote.testConnection()
            let count = me.items.map { " · \($0) artículos en el servidor" } ?? ""
            connectionMessage = "Conexión correcta\(count)."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    /// - Parameter force: ignore the foreground rate limit (launch, button, pull).
    @discardableResult
    func sync(force: Bool = true) async -> Bool {
        guard let remote = environment.remoteStore else { return false }
        isConfigured = environment.settings.isConfigured
        guard isConfigured else { return false }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.minimumForegroundInterval { return false }
        guard !isSyncing else { return false }
        isSyncing = true
        lastAttempt = Date()
        defer { isSyncing = false }
        do {
            let result = try await remote.sync()
            lastSyncAt = result.syncedAt
            lastError = nil
            catalogRevision += 1
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
