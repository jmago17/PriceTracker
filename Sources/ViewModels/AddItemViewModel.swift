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

    func lookUp() {
        errorMessage = nil
        preview = nil
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Esa no es una URL válida."
            return
        }
        guard let connector = environment.connectors.connectorToResolve(url: url) else {
            errorMessage = "Esta tienda todavía no está soportada (por ahora: App Store, Apple Books, Apple Music y Amazon — solo para guardar el enlace)."
            return
        }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                preview = try await connector.resolve(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Adds the previewed item. Returns the created `Item` so the caller can
    /// dismiss/navigate; throws if there is nothing previewed yet.
    @discardableResult
    func confirmAdd() async throws -> Item {
        guard let preview else { throw AddItemError.nothingToAdd }
        let item = Item(
            store: preview.store,
            storeItemID: preview.storeItemID,
            region: preview.region,
            currency: preview.currency,
            canonicalURL: preview.canonicalURL,
            title: preview.title,
            subtitle: preview.subtitle,
            imageURL: preview.imageURL,
            categorySource: .none,
            storeGenre: preview.storeGenre,
            priceCurrentCents: preview.priceCents,
            priceAtAddCents: preview.priceCents,
            priceReferenceCents: preview.priceReferenceCents,
            priceLowCents: preview.priceCents,
            priceLowAt: preview.priceCents != nil ? Date() : nil,
            lastCheckedAt: preview.priceCents != nil ? Date() : nil,
            lastSuccessAt: preview.priceCents != nil ? Date() : nil
        )
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
