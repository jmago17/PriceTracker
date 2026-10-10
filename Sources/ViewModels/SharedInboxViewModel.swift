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

    private func process(_ entry: SharedURLInbox.Entry) async {
        processingEntryID = entry.id
        defer { processingEntryID = nil }
        guard let url = URL(string: entry.urlString) else {
            inbox.markFailed(id: entry.id, error: "URL no válida")
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
