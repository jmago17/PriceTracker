@preconcurrency import CloudKit
import Foundation

/// Production does not yet contain PriceObservation. Keep samples durable locally
/// until a separately verified schema rollout enables their outbound transport.
enum HistoryTransportPolicy {
    static let enabled = false

    static func permits(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        let id: CKRecord.ID
        switch change {
        case .saveRecord(let value), .deleteRecord(let value): id = value
        @unknown default: return false
        }
        return enabled || !id.recordName.hasPrefix(CloudObservationCodec.prefix)
    }
}

/// Owns CKSyncEngine for the user's private database. The actor serializes
/// CloudKit delegate events with local-store updates and conflict resolution.
actor CloudSyncManager: CKSyncEngineDelegate {
    let statusStore: CloudSyncStatusStore

    private let localStore: SQLiteItemStore
    private let legacyJSONURL: URL
    private let suppliedContainer: CKContainer?
    // Defer CloudKit construction until sync is actually requested. Offline demo
    // and unit-test environments never need an account or a CloudKit connection.
    private lazy var container = suppliedContainer ?? CKContainer(identifier: CloudRecordIdentity.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
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
        container: CKContainer? = nil
    ) {
        self.localStore = localStore
        self.legacyJSONURL = legacyJSONURL
        self.statusStore = statusStore
        self.suppliedContainer = container
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
            for archive in try await localStore.retainedIncomingRecords() {
                do {
                    let record = try CloudRecordCodec.record(fromSystemFields: archive)
                    try await ingestFetchedRecord(record, syncEngine: engine)
                    try await localStore.removeRetainedIncomingRecord(named: record.recordID.recordName)
                    await statusStore.catalogDidChange()
                } catch { await report(error) }
            }
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
                try await localStore.prepareObservationSync()
                for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
                    // Persist before processing: a conflict must not discard
                    // this record or stop unrelated changes in the same batch.
                    try await localStore.retainIncomingRecord(named: modification.record.recordID.recordName,
                        archive: CloudRecordCodec.archivedSystemFields(modification.record))
                    do {
                        try await ingestFetchedRecord(modification.record, syncEngine: syncEngine)
                        try await localStore.removeRetainedIncomingRecord(named: modification.record.recordID.recordName)
                        catalogChanged = true
                    } catch { await report(error) }
                }
                for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                    if deletion.recordID.recordName.hasPrefix(CloudObservationCodec.prefix) {
                        try await localStore.tombstoneObservation(named: deletion.recordID.recordName)
                        if HistoryTransportPolicy.enabled {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
                        }
                        catalogChanged = true
                        continue
                    }
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
                    do { try await acknowledge(record, syncEngine: syncEngine) }
                    catch { await report(error) }
                }
                for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
                    do { try await handleFailedSave(failure, syncEngine: syncEngine) }
                    catch { await report(error) }
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
        // Also remove observations restored from an older serialized engine state.
        // This only changes the transport queue; SQLite dirty samples are retained.
        let blocked = syncEngine.state.pendingRecordZoneChanges.filter { !HistoryTransportPolicy.permits($0) }
        syncEngine.state.remove(pendingRecordZoneChanges: blocked)
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            HistoryTransportPolicy.permits($0) && context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [localStore, zoneID] recordID in
            guard recordID.zoneID == zoneID else { return nil }
            if recordID.recordName.hasPrefix(CloudObservationCodec.prefix) {
                guard let local = try? await localStore.observationRecords(named: recordID.recordName).first else { return nil }
                return try? CloudObservationCodec.makeRecord(local, zoneID: zoneID)
            }
            guard let local = try? await localStore.localRecord(named: recordID.recordName) else {
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
            var changes = try await localStore.dirtyRecords().map {
                CKSyncEngine.PendingRecordZoneChange.saveRecord(
                    CKRecord.ID(recordName: $0.recordName, zoneID: zoneID)
                )
            }
            if HistoryTransportPolicy.enabled {
                changes += try await localStore.dirtyObservationNames().map {
                    CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
                }
            }
            let blocked = engine.state.pendingRecordZoneChanges.filter { !HistoryTransportPolicy.permits($0) }
            engine.state.remove(pendingRecordZoneChanges: blocked)
            if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
            await statusStore.setPendingLocalChanges(changes.count)
        } catch {
            await report(error)
        }
    }

    private func ingestFetchedRecord(_ server: CKRecord, syncEngine: CKSyncEngine) async throws {
        if server.recordType == CloudObservationCodec.recordType {
            try await ingestObservation(server, syncEngine: syncEngine)
            return
        }
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

    private func ingestObservation(_ server: CKRecord, syncEngine: CKSyncEngine) async throws {
        try await localStore.applyRemoteObservation(CloudObservationCodec.decode(server))
        let id = server.recordID
        if HistoryTransportPolicy.enabled, try await localStore.observationRecords(named: id.recordName).first?.isDirty == true {
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        } else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        }
    }

    private func acknowledge(_ server: CKRecord, syncEngine: CKSyncEngine) async throws {
        if server.recordType == CloudObservationCodec.recordType {
            try await ingestObservation(server, syncEngine: syncEngine)
            return
        }
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
        if failure.record.recordType == CloudObservationCodec.recordType {
            guard HistoryTransportPolicy.enabled else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                return
            }
            switch error.code {
            case .serverRecordChanged:
                if let server = error.serverRecord {
                    try await localStore.retainIncomingRecord(named: server.recordID.recordName,
                        archive: CloudRecordCodec.archivedSystemFields(server))
                    try await ingestObservation(server, syncEngine: syncEngine)
                    try await localStore.removeRetainedIncomingRecord(named: server.recordID.recordName)
                    await statusStore.catalogDidChange()
                } else { await report(error) }
            case .unknownItem, .zoneNotFound:
                try await localStore.resetObservationSystemFields(named: failure.record.recordID.recordName)
                if error.code == .zoneNotFound {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
            default:
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                await report(error)
            }
            return
        }

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
            let items = try await localStore.dirtyCount()
            let observations = HistoryTransportPolicy.enabled ? try await localStore.dirtyObservationCount() : 0
            await statusStore.setPendingLocalChanges(items + observations)
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
