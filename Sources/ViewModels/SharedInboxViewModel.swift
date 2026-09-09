import Foundation
import Observation

@MainActor
@Observable
final class SharedInboxViewModel {
    private(set) var entries: [SharedURLInbox.Entry] = []
    private(set) var isProcessing = false

    private let inbox = SharedURLInbox()
    private let environment: AppEnvironment

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
        reload()
    }

    func reload() {
        entries = inbox.load()
    }

    func processAll() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false; reload() }
        for entry in inbox.load() {
            await process(entry)
        }
    }

    func retry(_ entry: SharedURLInbox.Entry) async {
        await process(entry)
        reload()
    }

    func delete(_ entry: SharedURLInbox.Entry) {
        inbox.remove(id: entry.id)
        reload()
    }

    private func process(_ entry: SharedURLInbox.Entry) async {
        guard let url = URL(string: entry.urlString) else {
            inbox.markFailed(id: entry.id, error: "Invalid URL")
            return
        }
        guard let connector = environment.connectors.connectorToResolve(url: url) else {
            inbox.markFailed(id: entry.id, error: "This store is not supported yet")
            return
        }
        do {
            let resolved = try await connector.resolve(url: url)
            let item = Item(
                store: resolved.store,
                storeItemID: resolved.storeItemID,
                region: resolved.region,
                currency: resolved.currency,
                canonicalURL: resolved.canonicalURL,
                title: resolved.title,
                subtitle: resolved.subtitle,
                imageURL: resolved.imageURL,
                storeGenre: resolved.storeGenre,
                priceCurrentCents: resolved.priceCents,
                priceAtAddCents: resolved.priceCents,
                priceReferenceCents: resolved.priceReferenceCents,
                priceLowCents: resolved.priceCents,
                priceLowAt: resolved.priceCents != nil ? .now : nil,
                lastCheckedAt: resolved.priceCents != nil ? .now : nil,
                lastSuccessAt: resolved.priceCents != nil ? .now : nil
            )
            try await environment.itemStore.upsert(item)
            inbox.remove(id: entry.id)
        } catch {
            inbox.markFailed(id: entry.id, error: error.localizedDescription)
        }
    }
}
