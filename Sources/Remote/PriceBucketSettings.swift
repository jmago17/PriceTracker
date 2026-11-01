import Foundation
import Security

/// Where the API key lives. Production uses the Keychain; tests inject a fake.
protocol KeyStoring: Sendable {
    func read() throws -> String?
    func write(_ value: String?) throws
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "No se pudo acceder al llavero (código \(status))." }
}

struct KeychainKeyStore: KeyStoring {
    var service = "com.maromeapps.PriceTracker.pricebucket"
    var account = "api-key"
    /// Keychain access group shared by the app and the Share extension. nil uses
    /// the target's default group. Without the entitlement (unit tests, unsigned
    /// builds) the keychain answers `errSecMissingEntitlement`, and every
    /// operation then falls back to the ungrouped item.
    var accessGroup: String? = KeychainKeyStore.sharedAccessGroup

    /// `$(AppIdentifierPrefix)com.maromeapps.PriceTracker`, expanded at build time
    /// into both Info.plists (`PriceBucketKeychainGroup`). An unexpanded value
    /// means the prefix was unavailable, so no group is used.
    static var sharedAccessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PriceBucketKeychainGroup") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    /// Runs `operation` against the shared group, retrying ungrouped when the
    /// group is not entitled.
    private func withGroupFallback<T>(_ operation: (String?) throws -> T) throws -> T {
        do {
            return try operation(accessGroup)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement && accessGroup != nil {
            return try operation(nil)
        }
    }

    func read() throws -> String? {
        try withGroupFallback { group in
            var query = baseQuery(group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
            return String(data: data, encoding: .utf8)
        }
    }

    func write(_ value: String?) throws {
        try withGroupFallback { group in
            guard let value else {
                let status = SecItemDelete(baseQuery(group: group) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
                return
            }
            let data = Data(value.utf8)
            let update = SecItemUpdate(baseQuery(group: group) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw KeychainError(status: update) }
            var add = baseQuery(group: group)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }
}

/// Server URL (App Group UserDefaults, so the Share extension reads it) and API
/// key (Keychain only, shared by access group). "Configured" means there is a
/// key. The key is never logged nor kept outside the Keychain.
final class PriceBucketSettings: Sendable {
    static let defaultBaseURL = URL(string: "https://pricebucket.pttpk8wmgy.workers.dev")!
    static let baseURLDefaultsKey = "pricebucket-base-url"

    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) static let sharedDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard

    nonisolated(unsafe) private let defaults: UserDefaults
    nonisolated(unsafe) private let legacyDefaults: UserDefaults?
    private let keyStore: any KeyStoring
    private let legacyKeyStore: (any KeyStoring)?

    /// - Parameters:
    ///   - legacyDefaults: where the server URL lived before the App Group move.
    ///   - legacyKeyStore: where the key lived before the shared access group.
    init(
        defaults: UserDefaults = PriceBucketSettings.sharedDefaults,
        keyStore: any KeyStoring = KeychainKeyStore(),
        legacyDefaults: UserDefaults? = nil,
        legacyKeyStore: (any KeyStoring)? = nil
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.legacyDefaults = legacyDefaults
        self.legacyKeyStore = legacyKeyStore
    }

    /// The app's own settings: they migrate from the standard defaults and from
    /// the ungrouped keychain item.
    static func forApp() -> PriceBucketSettings {
        PriceBucketSettings(legacyDefaults: .standard, legacyKeyStore: KeychainKeyStore(accessGroup: nil))
    }

    /// One-off copy of data written by earlier builds, run at app launch: the
    /// server URL from the standard defaults into the App Group suite, and a key
    /// present only in the ungrouped keychain into the shared group. Nothing
    /// already stored is overwritten, and a failure leaves the old value in place.
    func migrateLegacyStorage() {
        if let legacyDefaults, legacyDefaults !== defaults,
           let text = legacyDefaults.string(forKey: Self.baseURLDefaultsKey) {
            if defaults.object(forKey: Self.baseURLDefaultsKey) == nil {
                defaults.set(text, forKey: Self.baseURLDefaultsKey)
            }
            legacyDefaults.removeObject(forKey: Self.baseURLDefaultsKey)
        }
        if apiKey == nil,
           let legacyKey = (try? legacyKeyStore?.read()).flatMap({ $0 })?.trimmedNonEmpty {
            try? keyStore.write(legacyKey)
        }
    }

    var baseURL: URL {
        defaults.string(forKey: Self.baseURLDefaultsKey).flatMap(Self.validatedURL) ?? Self.defaultBaseURL
    }

    var apiKey: String? {
        (try? keyStore.read())?.trimmedNonEmpty
    }

    var isConfigured: Bool { apiKey != nil }

    /// Empty text restores the default URL. Only https is accepted (ATS).
    func setBaseURL(_ text: String) throws {
        guard let trimmed = text.trimmedNonEmpty else {
            defaults.removeObject(forKey: Self.baseURLDefaultsKey)
            return
        }
        guard let url = Self.validatedURL(trimmed) else {
            throw PriceBucketError.validation("La URL del servidor debe empezar por https:// y tener un dominio válido.")
        }
        if url == Self.defaultBaseURL { defaults.removeObject(forKey: Self.baseURLDefaultsKey) }
        else { defaults.set(url.absoluteString, forKey: Self.baseURLDefaultsKey) }
    }

    func setAPIKey(_ key: String?) throws {
        try keyStore.write(key?.trimmedNonEmpty)
    }

    func configuration() throws -> PriceBucketConfiguration {
        guard let key = apiKey else { throw PriceBucketError.notConfigured }
        return PriceBucketConfiguration(baseURL: baseURL, key: key)
    }

    static func validatedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
