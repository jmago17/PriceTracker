import Foundation
import Testing
@testable import PriceTracker

private struct FailingSpecificConnector: StoreConnector {
    let store: Store = .appStore
    func canResolve(url: URL) -> Bool { true }
    func resolve(url: URL) async throws -> ResolvedItem { throw ConnectorError.notFound }
    func fetch(_ item: Item) async throws -> FetchResult { throw ConnectorError.notFound }
}

private struct SuccessfulFallbackConnector: StoreConnector {
    let store: Store = .generic
    func canResolve(url: URL) -> Bool { true }
    func resolve(url: URL) async throws -> ResolvedItem {
        ResolvedItem(
            store: .generic,
            storeItemID: url.absoluteString,
            region: "ES",
            currency: "EUR",
            canonicalURL: url,
            title: "Fallback",
            subtitle: nil,
            imageURL: nil,
            priceCents: nil,
            priceReferenceCents: nil,
            storeGenre: nil
        )
    }
    func fetch(_ item: Item) async throws -> FetchResult { throw ConnectorError.notFound }
}

struct ConnectorRegistryTests {
    @Test func fallsBackWhenSpecificConnectorCannotExtractThePage() async throws {
        let registry = ConnectorRegistry(
            resolvers: [FailingSpecificConnector(), SuccessfulFallbackConnector()]
        )
        let url = try #require(URL(string: "https://tienda.example/producto"))

        let item = try await registry.resolve(url: url)

        #expect(item.store == .generic)
        #expect(item.title == "Fallback")
    }
}
