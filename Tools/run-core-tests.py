#!/usr/bin/env python3
"""Run selected production sources/tests on the Mac, without a simulator.
Only the composition root is replaced: no CloudKit/account/network/UI startup.
Requires Xcode 27 and macOS 27 for the existing IndexedEntityQuery API.
"""
from pathlib import Path
import os, shutil, subprocess
root = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('PRICETRACKER_TEST_BUILD', '/tmp/PriceTracker-core-tests'))
source = work/'Sources/PriceTracker'
tests = work/'Tests/PriceTrackerTests'
source.mkdir(parents=True, exist_ok=True); tests.mkdir(parents=True, exist_ok=True)
files = ['App/AppGroup.swift', 'AppIntents/SearchCatalogIntent.swift', 'Models/Item.swift', 'Models/Store.swift', 'Models/ItemStatus.swift', 'Models/PriceObservation.swift',
         'Persistence/CloudBackedItemStore.swift', 'Persistence/SQLiteItemStore.swift', 'Sync/CloudRecordIdentity.swift', 'Views/DateFormatting.swift', 'Persistence/ItemStoring.swift', 'Persistence/JSONFileStore.swift', 'Connectors/StoreConnector.swift',
         'Alerts/PriceDropDetector.swift', 'Alerts/AlertNotifier.swift', 'Refresh/RefreshCoordinator.swift',
         'Refresh/DailyRefreshSettings.swift', 'Refresh/ShortcutBridgeSettings.swift', 'AppIntents/ItemFilterEngine.swift', 'AppIntents/ItemEntity.swift',
         'AppIntents/ItemQuery.swift', 'AppIntents/RefreshItemIntent.swift', 'Views/MoneyFormatter.swift']
files += ['Models/CategoryLabel.swift', 'Sync/CloudRecordCodec.swift', 'Sync/CloudRecordMerger.swift']
test_names = ['AutomationTests.swift', 'ShortcutBridgeTests.swift', 'PriceDropDetectorTests.swift', 'ItemFilterEngineTests.swift']
if os.environ.get('PRICETRACKER_EXTENDED_TESTS') == '1':
    files += [str(p.relative_to(root/'Sources')) for p in (root/'Sources/Connectors').glob('*.swift') if p.name != 'StoreConnector.swift']
    test_names += ['AmazonConnectorTests.swift', 'WebPriceParserTests.swift', 'AppleStoreConnectorTests.swift', 'RefreshFeedbackTests.swift',
                   'GenericStoreConnectorTests.swift', 'WebPriceRefreshTests.swift', 'SQLiteItemStoreTests.swift',
                   'JSONFileItemStoreTests.swift', 'SharedURLInboxTests.swift', 'CloudRecordMergerTests.swift',
                   'CloudRecordIdentityTests.swift', 'ISOCountryCodesTests.swift', 'MoneyFormatterTests.swift']
    # Copy the transport gate verbatim, without starting CKSyncEngine/accounts.
    sync = (root/'Sources/Sync/CloudSyncManager.swift').read_text()
    (source/'HistoryTransportPolicy.swift').write_text(sync[:sync.index('/// Owns CKSyncEngine')])
# UNAuthorizationStatus.ephemeral is iOS-only; keep that suite unchanged for
# the native iOS runner instead of rewriting its production code/assertions.
files = [name for name in files if name != 'Refresh/ShortcutBridgeSettings.swift']
test_names.remove('ShortcutBridgeTests.swift')
print('Host excludes ShortcutBridgeTests (iOS-only ephemeral permission API)', flush=True)
for name in files: shutil.copy2(root/'Sources'/name, source/Path(name).name)
for name in test_names:
    shutil.copy2(root/'Tests/PriceTrackerTests'/name, tests/name)
(source/'TestComposition.swift').write_text('''import Foundation
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()
    let itemStore: any PriceHistoryStoring = EmptyStore()
    let alertStore: any AlertStoring = JSONFileAlertStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-test-alerts.json"))
    var refreshCoordinator: RefreshCoordinator { RefreshCoordinator(itemStore: itemStore, alertStore: alertStore, connectorToFetch: { _ in nil }) }
}
actor CloudSyncManager {
    func start() async {}
    func enqueueDirtyChanges() async {}
}
actor EmptyStore: PriceHistoryStoring {
    func loadAll() -> [Item] { [] }
    func save(_ items: [Item]) {}
    func upsert(_ item: Item, observation: PriceObservation) -> Item { item }
    func observations(for identityKey: String) -> [PriceObservation] { [] }
}
''')
(work/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PriceTracker", platforms: [.macOS("27.0")], targets: [
.target(name: "PriceTracker"), .testTarget(name: "PriceTrackerTests", dependencies: ["PriceTracker"])])
''')
print(f'Host test package: {work}', flush=True)
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', subprocess.check_output(['xcode-select', '-p'], text=True).strip())
raise SystemExit(subprocess.call(['xcrun', 'swift', 'test', '--package-path', str(work), '--jobs', '1'], env=env))
