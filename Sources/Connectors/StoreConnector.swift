import Foundation

struct ResolvedItem: Sendable {
    var store: Store
    var storeItemID: String
    var region: String
    var currency: String
    var canonicalURL: URL
    var title: String
    var subtitle: String?
    var imageURL: URL?
    var priceCents: Int?
    var priceReferenceCents: Int?
    var storeGenre: String?
}

struct FetchResult: Sendable {
    var priceCents: Int
    var currency: String
    var isOnSale: Bool
    var saleEndsAt: Date?
    var availability: String
    var title: String?
    var imageURL: URL?
    var storeGenre: String?
}

enum ConnectorError: Error, LocalizedError, Sendable {
    case unrecognizedURL
    case notSupported(String)
    case network(String)
    case decoding(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .unrecognizedURL: return "No se reconoce esta URL para ninguna tienda soportada."
        case .notSupported(let reason): return reason
        case .network(let reason): return "Error de red: \(reason)"
        case .decoding(let reason): return "Respuesta inesperada: \(reason)"
        case .notFound: return "No se encontró el artículo en la tienda."
        }
    }
}

/// One connector per store. `resolve` runs once, when adding an item from a URL;
/// `fetch` runs on every refresh. Kept as two separate operations because adding
/// and refreshing have different failure semantics (see architecture §d).
protocol StoreConnector: Sendable {
    var store: Store { get }
    func canResolve(url: URL) -> Bool
    func resolve(url: URL) async throws -> ResolvedItem
    func fetch(_ item: Item) async throws -> FetchResult
}
