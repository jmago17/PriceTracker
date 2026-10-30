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

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// Server URL (UserDefaults) and API key (Keychain only). "Configured" means
/// there is a key. The key is never logged nor kept outside the Keychain.
final class PriceBucketSettings: Sendable {
    static let defaultBaseURL = URL(string: "https://pricebucket.pttpk8wmgy.workers.dev")!
    static let baseURLDefaultsKey = "pricebucket-base-url"

    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let keyStore: any KeyStoring

    init(defaults: UserDefaults = .standard, keyStore: any KeyStoring = KeychainKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
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
