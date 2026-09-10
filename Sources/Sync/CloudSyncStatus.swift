import Foundation

enum CloudAccountState: String, Sendable {
    case checking = "Comprobando…"
    case available = "Disponible"
    case signedOut = "Sesión de iCloud cerrada"
    case restricted = "Acceso restringido"
    case temporarilyUnavailable = "Temporalmente no disponible"
    case couldNotDetermine = "No se pudo determinar"
    case accountChanged = "Cuenta distinta"
}

struct CloudSyncSnapshot: Equatable, Sendable {
    var accountState: CloudAccountState = .checking
    var lastSuccessfulSync: Date?
    var pendingLocalChanges: Int = 0
    var isSyncing = false
    var lastError: String?
    var catalogRevision = 0
}

actor CloudSyncStatusStore {
    private var value = CloudSyncSnapshot()

    func snapshot() -> CloudSyncSnapshot { value }

    func setAccountState(_ state: CloudAccountState) { value.accountState = state }
    func setPendingLocalChanges(_ count: Int) { value.pendingLocalChanges = count }
    func setSyncing(_ syncing: Bool) { value.isSyncing = syncing }
    func setLastError(_ message: String?) { value.lastError = message }
    func catalogDidChange() { value.catalogRevision += 1 }

    func markSuccessfulSync(at date: Date) {
        value.lastSuccessfulSync = date
    }

    func restoreLastSuccessfulSync(_ date: Date?) {
        value.lastSuccessfulSync = date
    }
}
