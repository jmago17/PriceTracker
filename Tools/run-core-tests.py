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
         'Persistence/SQLiteItemStore.swift', 'Sync/CloudRecordIdentity.swift', 'Views/DateFormatting.swift', 'Persistence/ItemStoring.swift', 'Persistence/JSONFileStore.swift', 'Connectors/StoreConnector.swift',
         'Alerts/PriceDropDetector.swift', 'Alerts/AlertNotifier.swift', 'Refresh/RefreshCoordinator.swift',
         'Refresh/DailyRefreshSettings.swift', 'AppIntents/ItemFilterEngine.swift', 'AppIntents/ItemEntity.swift',
         'AppIntents/ItemQuery.swift', 'AppIntents/RefreshItemIntent.swift', 'Views/MoneyFormatter.swift']
for name in files: shutil.copy2(root/'Sources'/name, source/Path(name).name)
for name in ['AutomationTests.swift', 'PriceDropDetectorTests.swift', 'ItemFilterEngineTests.swift']:
    shutil.copy2(root/'Tests/PriceTrackerTests'/name, tests/name)
(source/'TestComposition.swift').write_text('''import Foundation
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()
    let itemStore: any PriceHistoryStoring = EmptyStore()
    let alertStore: any AlertStoring = JSONFileAlertStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-test-alerts.json"))
    var refreshCoordinator: RefreshCoordinator { RefreshCoordinator(itemStore: itemStore, alertStore: alertStore, connectorToFetch: { _ in nil }) }
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
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode-beta.app/Contents/Developer')
raise SystemExit(subprocess.call(['xcrun', 'swift', 'test', '--package-path', str(work), '--jobs', '2'], env=env))
