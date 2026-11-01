#!/usr/bin/env python3
"""Run the unit tests on the Mac with SwiftPM, without a simulator.

Copies every non-UI production source (no Views/ViewModels/@main app) plus the
unit tests into a throwaway package and runs `swift test`. UI tests and anything
that needs UIKit/SwiftUI screens still require the iOS runner. Needs Xcode 27 and
macOS 27 (IndexedEntityQuery).
"""
from pathlib import Path
import os, shutil, subprocess

root = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('PRICETRACKER_TEST_BUILD', '/tmp/PriceTracker-core-tests'))
source = work / 'Sources/PriceTracker'
tests = work / 'Tests/PriceTrackerTests'
shutil.rmtree(work, ignore_errors=True)
source.mkdir(parents=True, exist_ok=True)
tests.mkdir(parents=True, exist_ok=True)

# Screens, their view models and the app entry point need UIKit/SwiftUI scenes.
excluded_dirs = {'ViewModels'}
host_views = {'DateFormatting.swift', 'MoneyFormatter.swift'}
excluded_files = {'PriceTrackerApp.swift', 'PriceTrackerShortcuts.swift'}
for path in sorted((root / 'Sources').rglob('*.swift')):
    relative = path.relative_to(root / 'Sources')
    if relative.parts[0] in excluded_dirs or path.name in excluded_files:
        continue
    if relative.parts[0] == 'Views' and path.name not in host_views:
        continue
    shutil.copy2(path, source / path.name)
for path in sorted((root / 'Tests/PriceTrackerTests').glob('*.swift')):
    # Imports UIKit; it runs on the iOS runner only.
    if path.name == 'DisplayTitleCacheTests.swift':
        continue
    shutil.copy2(path, tests / path.name)

(work / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PriceTracker", platforms: [.macOS("27.0")], targets: [
.target(name: "PriceTracker"), .testTarget(name: "PriceTrackerTests", dependencies: ["PriceTracker"])])
''')
print(f'Host test package: {work}', flush=True)
env = dict(os.environ)
# Xcode sets this for every test process; AppGroup.isDemo keys on it, and the
# composition root would otherwise try to open the real App Group container.
env.setdefault('XCTestConfigurationFilePath', 'host-runner')
env.setdefault('DEVELOPER_DIR', subprocess.check_output(['xcode-select', '-p'], text=True).strip())
raise SystemExit(subprocess.call(['xcrun', 'swift', 'test', '--package-path', str(work), '--jobs', '1'], env=env))
