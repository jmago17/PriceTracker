import Foundation
import Observation

@MainActor
@Observable
final class SyncViewModel {
    private(set) var snapshot = CloudSyncSnapshot()
    private let environment: AppEnvironment

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    func start() async {
        await environment.syncManager.start()
        await reload()
    }

    func syncNow() async {
        snapshot.isSyncing = true
        await environment.syncManager.syncNow()
        await reload()
    }

    func monitorStatus() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func reload() async {
        snapshot = await environment.syncManager.currentStatus()
    }
}
