import Foundation
import Observation

@MainActor
@Observable
final class AddItemViewModel {
    var urlText: String = ""
    private(set) var isResolving = false
    private(set) var preview: ResolvedItem?
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    /// Remote mode: the server resolves the link, so there is no local preview.
    var isRemote: Bool { environment.isRemote }

    /// `POST /items`. Amazon and blocked pages come back without a price and are
    /// shown as "Pendiente de primera comprobación" until the server checks them.
    @discardableResult
    func addToServer() async throws -> Item {
        guard let remote = environment.remoteStore else { throw AddItemError.nothingToAdd }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil else {
            throw PriceBucketError.validation("Esa no es una URL válida.")
        }
        isResolving = true
        defer { isResolving = false }
        return try await remote.add(url: url)
    }

    func lookUp() {
        errorMessage = nil
        preview = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Esa no es una URL válida."
            return
        }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                preview = try await environment.connectors.resolve(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// "Cambiar enlace": back to editing the URL, keeping its text.
    func reset() {
        preview = nil
        errorMessage = nil
    }

    /// "Guardar solo el enlace" on a failed/unrecognized URL: keeps the item
    /// (title derived from the URL itself) instead of losing the link because a
    /// store couldn't be parsed. Same `Item`/`itemStore` path as a normal add —
    /// just without a `ResolvedItem` to source metadata from.
    @discardableResult
    func saveLinkOnly() async throws -> Item {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw AddItemError.nothingToAdd }
        let title = url.host ?? trimmed
        let item = Item(
            store: .generic,
            storeItemID: trimmed,
            canonicalURL: url,
            title: title
        )
        return try await environment.itemStore.upsert(item)
    }

    /// Adds the previewed item. Returns the created `Item` so the caller can
    /// dismiss/navigate; throws if there is nothing previewed yet.
    @discardableResult
    func confirmAdd() async throws -> Item {
        guard let preview else { throw AddItemError.nothingToAdd }
        let item = Item(resolved: preview)
        return try await environment.itemStore.upsert(item)
    }
}

enum AddItemError: Error, LocalizedError {
    case nothingToAdd

    var errorDescription: String? {
        switch self {
        case .nothingToAdd: return "Busca primero un artículo antes de añadirlo."
        }
    }
}
