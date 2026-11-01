import Foundation
import Observation

@MainActor
@Observable
final class AddItemViewModel {
    var urlText: String = ""
    private(set) var isResolving = false
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    /// `POST /items`: the server reads the page. Amazon and blocked pages come
    /// back without a price and are shown as "Pendiente de primera comprobación"
    /// until the server checks them. In demo/XCTest (no server) only the link is
    /// saved, through the local store.
    @discardableResult
    func add() async throws -> Item {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw PriceBucketError.validation("Esa no es una URL válida.")
        }
        isResolving = true
        defer { isResolving = false }
        if let remote = environment.remoteStore {
            return try await remote.add(url: url)
        }
        let item = Item(store: .generic, storeItemID: trimmed, canonicalURL: url, title: url.host ?? trimmed)
        return try await environment.itemStore.upsert(item)
    }
}
