#!/usr/bin/env python3
"""Run production title, card, category and refresh tests on macOS without a simulator.

Copies production models, persistence contracts, connector contracts and the refresh
coordinator verbatim into a temporary Swift package. Only the iOS title layout test
and its UIKit/SwiftUI imports are excluded. Network and storage fakes live in tests.
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
        "Sources/Models/CatalogPriceCheck.swift",
        "Sources/Models/CatalogCardDetails.swift",
        "Sources/Models/CategoryLabel.swift",
        "Sources/AppIntents/ItemFilterEngine.swift",
        "Sources/Views/MoneyFormatter.swift",
        "Sources/Alerts/PriceDropDetector.swift",
        "Sources/Models/Store.swift",
        "Sources/Models/PriceObservation.swift",
        "Sources/Persistence/ItemStoring.swift",
        "Sources/Refresh/RefreshCoordinator.swift",
        "Sources/Connectors/StoreConnector.swift",
        "Sources/App/AppGroup.swift",
        "Sources/Models/ItemStatus.swift",
        "Sources/Sharing/ItemShareFormatter.swift",
    ]:
        shutil.copy2(root / relative, source)
    shutil.copy2(root / "Tests/PriceTrackerTests/CatalogPriceCheckTests.swift", tests)
    shutil.copy2(root / "Tests/PriceTrackerTests/CatalogCardDetailsTests.swift", tests)
    shutil.copy2(root / "Tests/PriceTrackerTests/CategoryLabelTests.swift", tests)
    shutil.copy2(root / "Tests/PriceTrackerTests/RefreshFeedbackTests.swift", tests)
    test_source = (root / "Tests/PriceTrackerTests/DisplayTitleCacheTests.swift").read_text()
    pure_tests, marker, _ = test_source.partition("\n@MainActor\nstruct CatalogTitleLayoutTests")
    assert marker, "UI test boundary changed; update the host harness"
    pure_tests = pure_tests.replace("import SwiftUI\n", "").replace("import UIKit\n", "")
    (tests / "DisplayTitleCacheTests.swift").write_text(pure_tests)
    environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swift", "test", "--jobs", "2", "--package-path", str(package)],
                   env=environment, check=True)
