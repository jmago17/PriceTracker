import Foundation
import Observation

@MainActor
@Observable
final class SharedInboxViewModel {
    private(set) var entries: [SharedURLInbox.Entry] = []
    private(set) var isProcessing = false
    private(set) var processingEntryID: UUID?

    /// Set by the root view so shared links get the same summary as manual adds.
    var onItemAdded: (@MainActor (Item, String?) async -> Void)?

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

    /// Remote mode: the server resolves the link. Created or already-existing
    /// links leave the inbox; failures stay there to be retried. Without a key
    /// no request is made; the entry just records why it is waiting.
    private func sendToServer(_ entry: SharedURLInbox.Entry, url: URL, remote: RemoteItemStore) async {
        guard remote.isConfigured else {
            inbox.markFailed(id: entry.id, error: PriceBucketError.notConfigured.localizedDescription)
            return
        }
        do {
            let stored = try await remote.add(url: url)
            inbox.remove(id: entry.id)
            await onItemAdded?(stored, nil)
        } catch let error as PriceBucketError where error.isAlreadyExists {
            inbox.remove(id: entry.id)
        } catch {
            inbox.markFailed(id: entry.id, error: error.localizedDescription)
        }
    }

    private func process(_ entry: SharedURLInbox.Entry) async {
        processingEntryID = entry.id
        defer { processingEntryID = nil }
        guard let url = URL(string: entry.urlString) else {
            inbox.markFailed(id: entry.id, error: "URL no válida")
            return
        }
        if let remote = environment.remoteStore {
            await sendToServer(entry, url: url, remote: remote)
            return
        }
        do {
            let resolved = try await environment.connectors.resolve(
                url: url,
                pageCapture: entry.pageCapture
            )
            let item = Item(resolved: resolved)
            let stored = try await environment.itemStore.upsert(item)
            inbox.remove(id: entry.id)
            await onItemAdded?(stored, resolved.pageText)
        } catch {
            inbox.markFailed(id: entry.id, error: error.localizedDescription)
        }
    }
}
