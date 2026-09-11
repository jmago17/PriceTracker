@preconcurrency import CloudKit
import Foundation

/// Owns CKSyncEngine for the user's private database. The actor serializes
/// CloudKit delegate events with local-store updates and conflict resolution.
actor CloudSyncManager: CKSyncEngineDelegate {
    let statusStore: CloudSyncStatusStore

    private let localStore: SQLiteItemStore
    private let legacyJSONURL: URL
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudRecordIdentity.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private var engine: CKSyncEngine?
    private var started = false
    private var accountAllowsSync = false
    private var manualSyncInProgress = false
    private var failureGeneration = 0

    init(
        localStore: SQLiteItemStore,
        legacyJSONURL: URL,
        statusStore: CloudSyncStatusStore = CloudSyncStatusStore(),
        container: CKContainer = CKContainer(identifier: CloudRecordIdentity.containerIdentifier)
    ) {
        self.localStore = localStore
        self.legacyJSONURL = legacyJSONURL
        self.statusStore = statusStore
        self.container = container
        self.database = container.privateCloudDatabase
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            _ = try await localStore.migrateLegacyJSONIfNeeded(from: legacyJSONURL)
            try await restoreLastSuccessfulSync()
            await refreshAccountStatus()

            let serialization: CKSyncEngine.State.Serialization?
            if let data = try await localStore.metadataData(for: SQLiteItemStore.syncStateMetadataKey) {
                do {
                    serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
                } catch {
                    serialization = nil
                    await statusStore.setLastError("El estado anterior de sincronización estaba dañado; se reconstruirá.")
                }
            } else {
                serialization = nil
            }

            var configuration = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: serialization,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = "PriceTrackerCatalogChanges"
            let engine = CKSyncEngine(configuration)
            self.engine = engine

            let zone = CKRecordZone(zoneID: zoneID)
            let saveZone = CKSyncEngine.PendingDatabaseChange.saveZone(zone)
            if !engine.state.pendingDatabaseChanges.contains(saveZone) {
                engine.state.add(pendingDatabaseChanges: [saveZone])
            }
            await addDirtyRecordsToEngine()
        } catch {
            started = false
            await report(error)
        }
    }

    /// Called after local commits. It only updates CKSyncEngine's durable
    /// pending set; automatic sending happens independently.
    func enqueueDirtyChanges() async {
        if !started { await start() }
        guard engine != nil else { return }
        await addDirtyRecordsToEngine()
    }

    func syncNow() async {
        guard !manualSyncInProgress else { return }
        manualSyncInProgress = true
        defer { manualSyncInProgress = false }
        if !started { await start() }
        await refreshAccountStatus()
        guard let engine, accountAllowsSync else {
            await updatePendingCount()
            return
        }

        await statusStore.setSyncing(true)
        let startingFailureGeneration = failureGeneration
        do {
            await addDirtyRecordsToEngine()
            // The first send creates the custom zone when necessary. Fetching
            // then resolves remote edits before the final send of merged rows.
            try await engine.sendChanges()
            try await engine.fetchChanges()
            try await engine.sendChanges()
            if failureGeneration == startingFailureGeneration {
                try await markSuccessfulSync()
                await statusStore.setLastError(nil)
            }
        } catch {
            await report(error)
        }
        await statusStore.setSyncing(false)
        await updatePendingCount()
    }

    func refreshAccountStatus() async {
        do {
            switch try await container.accountStatus() {
            case .available:
                let userRecordName = try await container.userRecordID().recordName
                let previous = try await localStore.metadataData(for: SQLiteItemStore.accountMetadataKey)
                    .flatMap { String(data: $0, encoding: .utf8) }
                if let previous, previous != userRecordName {
                    accountAllowsSync = false
                    await statusStore.setAccountState(.accountChanged)
                    await statusStore.setLastError(
                        "La cuenta de iCloud cambió. El catálogo local no se enviará a otra cuenta. Vuelve a la cuenta anterior para reintentar."
                    )
                } else {
                    if previous == nil {
                        try await localStore.setMetadataData(
                            Data(userRecordName.utf8),
                            for: SQLiteItemStore.accountMetadataKey
                        )
                    }
                    accountAllowsSync = true
                    await statusStore.setAccountState(.available)
                    await statusStore.setLastError(nil)
                }
            case .noAccount:
                accountAllowsSync = false
                await statusStore.setAccountState(.signedOut)
                await statusStore.setLastError("Inicia sesión en iCloud para sincronizar. El catálogo local sigue disponible.")
            case .restricted:
                accountAllowsSync = false
                await statusStore.setAccountState(.restricted)
                await statusStore.setLastError("CloudKit está restringido por el sistema o por gestión del dispositivo.")
            case .temporarilyUnavailable:
                accountAllowsSync = false
                await statusStore.setAccountState(.temporarilyUnavailable)
                await statusStore.setLastError("iCloud no está disponible temporalmente. Reintenta más tarde.")
            case .couldNotDetermine:
                accountAllowsSync = false
                await statusStore.setAccountState(.couldNotDetermine)
                await statusStore.setLastError("No se pudo determinar el estado de la cuenta de iCloud.")
            @unknown default:
                accountAllowsSync = false
                await statusStore.setAccountState(.couldNotDetermine)
                await statusStore.setLastError("Estado de cuenta iCloud desconocido.")
            }
        } catch {
            accountAllowsSync = false
            await statusStore.setAccountState(.couldNotDetermine)
            await report(error)
        }
        await updatePendingCount()
    }

    func currentStatus() async -> CloudSyncSnapshot {
        await statusStore.snapshot()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try JSONEncoder().encode(update.stateSerialization)
                try await localStore.setMetadataData(data, for: SQLiteItemStore.syncStateMetadataKey)

            case .accountChange(let change):
                switch change.changeType {
                case .signOut:
                    accountAllowsSync = false
                    await statusStore.setAccountState(.signedOut)
                case .signIn, .switchAccounts:
                    await refreshAccountStatus()
                    if accountAllowsSync { await addDirtyRecordsToEngine() }
                @unknown default:
                    accountAllowsSync = false
                    await statusStore.setAccountState(.couldNotDetermine)
                }

            case .fetchedRecordZoneChanges(let changes):
                guard accountAllowsSync else { break }
                var catalogChanged = false
                for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
                    try await ingestFetchedRecord(modification.record, syncEngine: syncEngine)
                    catalogChanged = true
                }
                for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                    if try await localStore.turnPhysicalServerDeletionIntoTombstone(
                        recordName: deletion.recordID.recordName
                    ) {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
                        catalogChanged = true
                    }
                }
                if catalogChanged { await statusStore.catalogDidChange() }

            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords where record.recordID.zoneID == zoneID {
                    try await acknowledge(record, syncEngine: syncEngine)
                }
                for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
                    try await handleFailedSave(failure, syncEngine: syncEngine)
                }
                if let error = changes.failedRecordDeletes.values.first {
                    await report(error)
                }

            case .sentDatabaseChanges(let changes):
                if let failure = changes.failedZoneSaves.first {
                    await report(failure.error)
                } else if let error = changes.failedZoneDeletes.values.first {
                    await report(error)
                }

            case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
                await statusStore.setSyncing(true)

            case .didFetchRecordZoneChanges(let event):
                if let error = event.error { await report(error) }

            case .didFetchChanges, .didSendChanges:
                await statusStore.setSyncing(false)
                try await markSuccessfulSync()

            case .fetchedDatabaseChanges:
                break
            @unknown default:
                break
            }
        } catch {
            await report(error)
        }
        await updatePendingCount()
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard accountAllowsSync else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [localStore, zoneID] recordID in
            guard recordID.zoneID == zoneID,
                  let local = try? await localStore.localRecord(named: recordID.recordName) else {
                return nil
            }
            return try? CloudRecordCodec.makeRecord(from: local, zoneID: zoneID)
        }
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        options.prioritizedZoneIDs = [zoneID]
        return options
    }

    private func addDirtyRecordsToEngine() async {
        guard let engine else { return }
        do {
            let changes = try await localStore.dirtyRecords().map {
                CKSyncEngine.PendingRecordZoneChange.saveRecord(
                    CKRecord.ID(recordName: $0.recordName, zoneID: zoneID)
                )
            }
            if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
            await statusStore.setPendingLocalChanges(changes.count)
        } catch {
            await report(error)
        }
    }

    private func ingestFetchedRecord(_ server: CKRecord, syncEngine: CKSyncEngine) async throws {
        guard server.recordType == CloudRecordCodec.recordType else { return }
        let identityKey = try CloudRecordCodec.identityKey(server)
        let expectedName = CloudRecordIdentity.recordName(for: identityKey)
        guard server.recordID.recordName == expectedName else {
            throw CloudRecordCodecError.invalidRecord("recordName")
        }

        let local = try await localStore.localRecord(named: expectedName)
        let serverArchive = try CloudRecordCodec.archivedSystemFields(server)
        if CloudRecordCodec.isTombstone(server) {
            try await localStore.applyRemote(
                recordName: expectedName,
                identityKey: identityKey,
                item: nil,
                isTombstone: true,
                systemFields: serverArchive,
                dirty: false
            )
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            return
        }

        if let local, local.isDirty {
            let client = try CloudRecordCodec.makeRecord(from: local, zoneID: zoneID)
            let ancestor = try local.systemFields.map(CloudRecordCodec.record(fromSystemFields:))
            let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
            if CloudRecordCodec.isTombstone(merged) {
                try await localStore.applyRemote(
                    recordName: expectedName,
                    identityKey: identityKey,
                    item: nil,
                    isTombstone: true,
                    systemFields: serverArchive,
                    dirty: false
                )
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            } else {
                let item = try CloudRecordCodec.item(from: merged, preservingDeviceFieldsFrom: local.item)
                try await localStore.applyRemote(
                    recordName: expectedName,
                    identityKey: identityKey,
                    item: item,
                    isTombstone: false,
                    systemFields: serverArchive,
                    dirty: true
                )
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            }
        } else {
            let item = try CloudRecordCodec.item(from: server, preservingDeviceFieldsFrom: local?.item)
            try await localStore.applyRemote(
                recordName: expectedName,
                identityKey: identityKey,
                item: item,
                isTombstone: false,
                systemFields: serverArchive,
                dirty: false
            )
        }
    }

    private func acknowledge(_ server: CKRecord, syncEngine: CKSyncEngine) async throws {
        guard let local = try await localStore.localRecord(named: server.recordID.recordName) else { return }
        let matches = try CloudRecordCodec.matches(local: local, serverRecord: server, zoneID: zoneID)
        let remainsDirty = try await localStore.acknowledgeSavedRecord(
            named: server.recordID.recordName,
            systemFields: CloudRecordCodec.archivedSystemFields(server),
            matchesCurrentLocalValue: matches
        )
        if remainsDirty {
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        }
    }

    private func handleFailedSave(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) async throws {
        let error = failure.error

        switch error.code {
        case .unknownItem:
            // The cached server record carries a changeTag, but that record no
            // longer exists in this database. Recreate it from the intact local
            // row on the next attempt, as recommended by Apple's CKSyncEngine
            // sample.
            try await localStore.clearSystemFields(named: failure.record.recordID.recordName)
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            return

        case .zoneNotFound:
            // A recreated zone invalidates every cached recordChangeTag used by
            // this attempted save. Clear this row, recreate the zone, and retry.
            try await localStore.clearSystemFields(named: failure.record.recordID.recordName)
            let zone = CKRecordZone(zoneID: failure.record.recordID.zoneID)
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            return

        case .serverRecordChanged:
            break

        default:
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            await report(error)
            return
        }

        guard let server = error.serverRecord else {
            await report(error)
            return
        }
        guard let local = try await localStore.localRecord(named: server.recordID.recordName) else { return }
        let client = try CloudRecordCodec.makeRecord(from: local, zoneID: zoneID)
        let storedAncestor = try local.systemFields.map(CloudRecordCodec.record(fromSystemFields:))
        let ancestor = error.ancestorRecord ?? storedAncestor
        let merged = try CloudRecordMerger.merge(ancestor: ancestor, client: client, server: server)
        let identityKey = try CloudRecordCodec.identityKey(merged)
        let serverArchive = try CloudRecordCodec.archivedSystemFields(server)

        if CloudRecordCodec.isTombstone(merged) {
            let needsUpload = CloudRecordCodec.isTombstone(client) && !CloudRecordCodec.isTombstone(server)
            try await localStore.applyRemote(
                recordName: server.recordID.recordName,
                identityKey: identityKey,
                item: nil,
                isTombstone: true,
                systemFields: serverArchive,
                dirty: needsUpload
            )
            if needsUpload {
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            }
        } else {
            let item = try CloudRecordCodec.item(from: merged, preservingDeviceFieldsFrom: local.item)
            try await localStore.applyRemote(
                recordName: server.recordID.recordName,
                identityKey: identityKey,
                item: item,
                isTombstone: false,
                systemFields: serverArchive,
                dirty: true
            )
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        }
        await statusStore.catalogDidChange()
    }

    private func markSuccessfulSync() async throws {
        let now = Date()
        try await localStore.setMetadataData(
            Data(String(now.timeIntervalSince1970).utf8),
            for: SQLiteItemStore.lastSuccessfulSyncMetadataKey
        )
        await statusStore.markSuccessfulSync(at: now)
    }

    private func restoreLastSuccessfulSync() async throws {
        let date = try await localStore.metadataData(for: SQLiteItemStore.lastSuccessfulSyncMetadataKey)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        await statusStore.restoreLastSuccessfulSync(date)
    }

    private func updatePendingCount() async {
        do {
            await statusStore.setPendingLocalChanges(try await localStore.dirtyCount())
        } catch {
            await report(error)
        }
    }

    private func report(_ error: Error) async {
        failureGeneration += 1
        await statusStore.setLastError(error.localizedDescription)
        await statusStore.setSyncing(false)
    }
}
