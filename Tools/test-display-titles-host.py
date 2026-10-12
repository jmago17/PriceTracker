#!/usr/bin/env python3
"""Run the production title-cache tests on macOS without a simulator.

Copies production value types/cache verbatim into a temporary Swift package.
Only the iOS UI layout test and its UIKit/SwiftUI imports are excluded. The
ResolvedItem declaration is copied from its source; no model/generator is stubbed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="pricetracker-title-tests-") as temporary:
    package = Path(temporary)
    source = package / "Sources" / "PriceTracker"
    tests = package / "Tests" / "PriceTrackerTests"
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "PriceTrackerTitleTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "PriceTracker"),
        .testTarget(name: "PriceTrackerTests", dependencies: ["PriceTracker"])
    ]
)
''')
    for relative in [
        "Sources/Intelligence/DisplayTitleCache.swift",
        "Sources/Models/Item.swift",
        "Sources/Models/Store.swift",
        "Sources/Models/ItemStatus.swift",
        "Sources/Sharing/ItemShareFormatter.swift",
    ]:
        shutil.copy2(root / relative, source)
    connector = (root / "Sources/Connectors/StoreConnector.swift").read_text()
    resolved, marker, _ = connector.partition("\nstruct FetchResult:")
    assert marker, "ResolvedItem declaration boundary changed; update the host harness"
    (source / "ResolvedItem.swift").write_text(resolved)
    test_source = (root / "Tests/PriceTrackerTests/DisplayTitleCacheTests.swift").read_text()
    pure_tests, marker, _ = test_source.partition("\n@MainActor\nstruct CatalogTitleLayoutTests")
    assert marker, "UI test boundary changed; update the host harness"
    pure_tests = pure_tests.replace("import SwiftUI\n", "").replace("import UIKit\n", "")
    (tests / "DisplayTitleCacheTests.swift").write_text(pure_tests)
    environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swift", "test", "--package-path", str(package)],
                   env=environment, check=True)
