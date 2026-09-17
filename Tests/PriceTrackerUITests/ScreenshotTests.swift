import XCTest

/// Not a correctness suite — a visual-QA driver. No AXe/idb/Simulator.app GUI
/// is available on this host, so XCUITest is the only way to drive real taps
/// against a booted simulator to compare the redesign against the handoff's
/// PNGs. Screenshots land on the Mac's filesystem directly (this test body
/// runs host-side), under /tmp/pricetracker_final_*.png.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureAllScreens() throws {
        let app = XCUIApplication()
        app.launch()

        dismissNotificationPromptIfPresent(app)

        save(app.screenshot(), to: "catalog_light")

        // Scroll to the very end of the catalog list — the floating tab bar
        // must not cover the last "Siguiendo" rows once fully scrolled.
        let catalogList = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        if catalogList.waitForExistence(timeout: 3) {
            for _ in 0..<6 {
                catalogList.swipeUp(velocity: .fast)
            }
            Thread.sleep(forTimeInterval: 0.3)
            save(app.screenshot(), to: "catalog_scrolled_end")
            for _ in 0..<6 {
                catalogList.swipeDown(velocity: .fast)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Detail — first row under "Bajadas de precio".
        let row = app.descendants(matching: .any)["item-row"].firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
            save(app.screenshot(), to: "detail_no_history")
            if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 3) {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }

        // Add URL sheet.
        let addButton = app.descendants(matching: .any)["add-item-button"].firstMatch
        if addButton.waitForExistence(timeout: 5) {
            addButton.tap()
            _ = app.textViews.firstMatch.waitForExistence(timeout: 3)
            save(app.screenshot(), to: "add_url_idle")

            let field = app.textViews.firstMatch
            if field.exists {
                field.tap()
                field.typeText("https://apps.apple.com/es/app/overcast/id888422857")
                let analyze = app.buttons["Analizar enlace"]
                if analyze.waitForExistence(timeout: 2) {
                    analyze.tap()
                    // Resolution hits the real App Store lookup API — give it a
                    // real round trip instead of a fixed guess.
                    _ = app.staticTexts["Precio detectado"].waitForExistence(timeout: 12)
                        || app.buttons["Reintentar"].waitForExistence(timeout: 12)
                    save(app.screenshot(), to: "add_url_resolved")
                }
            }
            if app.buttons["Cancelar"].waitForExistence(timeout: 2) {
                app.buttons["Cancelar"].tap()
            }
        }

        // Bandeja tab.
        let inboxTab = app.tabBars.buttons["Bandeja"]
        if inboxTab.waitForExistence(timeout: 3) {
            inboxTab.tap()
            Thread.sleep(forTimeInterval: 1)
            save(app.screenshot(), to: "inbox")
        }

        // Ajustes tab → Sincronización.
        let settingsTab = app.tabBars.buttons["Ajustes"]
        if settingsTab.waitForExistence(timeout: 3) {
            settingsTab.tap()
            Thread.sleep(forTimeInterval: 1)
            save(app.screenshot(), to: "settings")
            let syncRow = app.descendants(matching: .any)["settings-sync-row"].firstMatch
            if syncRow.waitForExistence(timeout: 3) {
                syncRow.tap()
                Thread.sleep(forTimeInterval: 1)
                save(app.screenshot(), to: "sync")
            }
        }
    }

    private func dismissNotificationPromptIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    private func save(_ screenshot: XCUIScreenshot, to name: String) {
        let suffix = ProcessInfo.processInfo.environment["PT_SCREENSHOT_SUFFIX"] ?? ""
        let path = "/tmp/pricetracker_final_\(name)\(suffix).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
