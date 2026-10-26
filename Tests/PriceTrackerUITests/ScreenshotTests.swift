import XCTest
import UIKit

final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitialPriceAndPriorityInSpanishAndEnglish() throws {
        for (language, locale, resetTitle, highTitle) in [
            ("es", "es_ES", "Usar precio actual como inicial", "Alta"),
            ("en", "en_US", "Use current price as initial", "High")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            let item = firstItemElement(app)
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            item.tap()
            let reset = app.buttons["reset-initial-price"]
            for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
            XCTAssertTrue(reset.exists)
            XCTAssertEqual(reset.label, resetTitle)
            XCTAssertTrue(reset.isEnabled)
            let priority = app.buttons["item-priority"]
            XCTAssertTrue(priority.exists)
            priority.tap()
            app.buttons[highTitle].tap()
            reset.tap()
            capture(app, "initial_priority_\(language)")
            app.terminate()
        }
    }

    func testIPadCatalogActionsStayInNavigationBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog"]
        app.launch()
        guard app.scrollViews["catalog-mural-regular"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Ejecutar en iPad")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "iPad toolbar hierarchy \(orientation.rawValue)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            // Landscape can expose a sidebar navigation bar before the
            // catalog bar. Select by the control's owner, not tree order.
            let bar = app.navigationBars.containing(.button, identifier: "mural-search-button").firstMatch
            for identifier in ["mural-search-button", "mural-refresh-button", "mural-status-filter-menu", "add-item-button"] {
                let control = bar.buttons[identifier]
                XCTAssertTrue(control.waitForExistence(timeout: 5), identifier)
                XCTAssertTrue(control.isHittable, identifier)
            }
            let cards = app.descendants(matching: .any).matching(identifier: "item-card")
            let frames = uniqueCardFrames(cards)
            let columns = Dictionary(grouping: frames, by: { Int($0.minX.rounded()) })
                .sorted { $0.key < $1.key }
                .compactMap { $0.value.min(by: { $0.minY < $1.minY }) }
            if columns.count >= 3 {
                XCTAssertEqual(columns[0].minY, columns[2].minY, accuracy: 2)
            }
            if columns.count >= 4 {
                XCTAssertEqual(columns[1].minY, columns[3].minY, accuracy: 2)
                XCTAssertEqual(columns[1].minY - columns[0].minY, 52, accuracy: 2)
            }
            capture(app, "ipad_native_toolbar_\(orientation.rawValue)")
        }
        app.navigationBars.buttons["mural-search-button"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["dismiss-mural-keyboard-button"].tap()
        app.navigationBars.buttons["mural-status-filter-menu"].tap()
        XCTAssertTrue(app.buttons["Menos que al añadir"].waitForExistence(timeout: 5))
    }

    func testSyntheticCatalogAndDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Observar. Comparar. Decidir."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Libros"].firstMatch.exists)
        capture(app, "catalog")
        let row = app.descendants(matching: .any)["item-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Comparación histórica; no confirma una promoción de la tienda."].waitForExistence(timeout: 5))
        capture(app, "detail")
    }

    func testSearchAndCategoryFilter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Observar. Comparar. Decidir."].waitForExistence(timeout: 10))
        app.scrollViews["catalog-filters"].swipeLeft()
        app.buttons["category-filter-menu"].tap()
        app.buttons["Libros"].tap()
        XCTAssertTrue(app.staticTexts["Libros"].firstMatch.exists)
        capture(app, "category_filter")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("zz_no_results_123")
        XCTAssertTrue(app.staticTexts["Sin resultados"].waitForExistence(timeout: 5))
        capture(app, "search_empty")
    }

    func testDarkLargeTextAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO", "-AppleInterfaceStyle", "Dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["add-item-button"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["add-item-button"].label, "Añadir artículo")
        XCTAssertTrue(app.buttons["Opciones del catálogo"].exists)
        capture(app, "catalog_dark_large_text")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])
    }

    func testSamePriceRefreshUpdatesFreshnessAndDrawsFlatHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO", "--demo-history"]
        app.launch()
        let row = app.descendants(matching: .any)["item-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let onePoint = app.staticTexts["Una comprobación: todavía no hay un intervalo que comparar."]
        app.swipeUp()
        XCTAssertTrue(onePoint.waitForExistence(timeout: 5))
        capture(app, "history_single_point")
        let refresh = app.buttons["Actualizar"]
        if !refresh.isHittable { app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(app.staticTexts["Comprobado ahora"].firstMatch.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Mismo precio en las comprobaciones registradas."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["price-history-chart"].exists)
        capture(app, "history_flat_after_refresh")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // ItemRowView combines its children into one accessibility element.
        let refreshedRow = app.descendants(matching: .any)["item-row"].firstMatch
        XCTAssertTrue(refreshedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(refreshedRow.label.contains("Última comprobación correcta: ahora"))
        capture(app, "catalog_fresh_after_equal_price")
    }

    func testRefreshDiagnosticsLightAndDarkAccessibility() throws {
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO", "--demo-history"]
            if dark {
                app.launchArguments += ["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.buttons["add-item-button"].waitForExistence(timeout: 10))
            let row = app.descendants(matching: .any)["item-row"].firstMatch
            // At accessibility XXXL the catalog header can fill the viewport;
            // materialize the lazy row by scrolling instead of assuming it exists.
            for _ in 0..<8 {
                if row.exists { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            app.buttons["Opciones del artículo"].tap()
            app.buttons["Diagnóstico"].tap()
            XCTAssertTrue(app.navigationBars["Diagnóstico"].waitForExistence(timeout: 5))
            let report = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Price Bucket · diagnóstico local v1")).firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 5))
            XCTAssertTrue(report.label.contains("Sin intentos registrados"))
            XCTAssertFalse(report.label.contains("https://"))
            capture(app, dark ? "diagnostics_dark_accessibility" : "diagnostics_light")
            let share = app.buttons["share-refresh-diagnostics"]
            for _ in 0..<8 {
                if share.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(share.exists && share.isHittable)
            XCTAssertFalse(share.label.isEmpty)
            try app.performAccessibilityAudit(for: [.sufficientElementDescription])
            app.buttons["Cerrar"].tap()
            let refresh = app.buttons["Actualizar"]
            for _ in 0..<8 {
                if refresh.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(refresh.isHittable)
            refresh.tap()
            XCTAssertTrue(app.staticTexts["Comprobado ahora"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["Opciones del artículo"].tap()
            app.buttons["Diagnóstico"].tap()
            let completed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Price Bucket · diagnóstico local v1")).firstMatch
            XCTAssertTrue(completed.waitForExistence(timeout: 5))
            XCTAssertTrue(completed.label.contains("completado · success"))
            XCTAssertFalse(completed.label.contains("https://"))
            capture(app, dark ? "diagnostics_success_dark_accessibility" : "diagnostics_success_light")
            app.buttons["Cerrar"].tap()
            app.terminate()
        }
    }

    func testHistoryDoesNotInventOlderObservations() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO", "--demo-history", "--demo-history-empty"]
        app.launch()
        let row = app.descendants(matching: .any)["item-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Todavía sin observaciones"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["price-history-chart"].exists)
        capture(app, "history_empty")
    }

    func testContextMenuShare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        let item = firstItemElement(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Compartir"].waitForExistence(timeout: 5))
        capture(app, "context_menu_share")
    }

    func testSelectionShareBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        let item = firstItemElement(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))

        if app.buttons["start-selection-button"].exists {
            app.buttons["start-selection-button"].tap()
        } else {
            app.buttons["Opciones del catálogo"].tap()
            app.buttons["Seleccionar"].tap()
        }
        firstItemElement(app).tap()
        XCTAssertTrue(app.buttons["share-selection-button"].waitForExistence(timeout: 5))
        capture(app, "selection_share_bar")
    }

    func testItemDetailShare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        let item = firstItemElement(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        XCTAssertTrue(app.buttons["share-item-button"].waitForExistence(timeout: 5))
        capture(app, "detail_share")
    }

    /// Covers an item that carries size/color (`variantChips`), distinct from
    /// `testItemDetailShare`'s item which only has a summary.
    func testItemDetailVariantChips() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Camiseta")
        let row = firstItemElement(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Verde oliva"].waitForExistence(timeout: 5))
        capture(app, "detail_variant_chips")
    }

    /// Only meaningful on a regular-width device (iPad); skips cleanly otherwise
    /// rather than asserting a layout that an iPhone destination never shows.
    func testMuralLandscapeAndPortrait() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        guard app.scrollViews["catalog-mural-regular"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Mural solo aparece en ancho regular (iPad)")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Camiseta básica"].waitForExistence(timeout: 5))
        // The element exists as soon as the rotation starts, well before the
        // interface finishes animating to it — without this the screenshot
        // captures the old portrait layout rendered into a landscape-shaped
        // buffer (confirmed on a real capture: sideways text, black bars).
        Thread.sleep(forTimeInterval: 1)
        capture(app, "mural_landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Camiseta básica"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        capture(app, "mural_portrait")
    }

    func testAdaptiveMuralLargeTextControlsAndLastCard() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let regular = app.scrollViews["catalog-mural-regular"]
        let compact = app.scrollViews["catalog-mural-compact"]
        XCTAssertTrue(regular.waitForExistence(timeout: 3) || compact.waitForExistence(timeout: 3))
        let scroll = regular.exists ? regular : compact
        let cards = app.descendants(matching: .any).matching(identifier: "item-card")
        guard cards.firstMatch.waitForExistence(timeout: 5) else {
            XCTFail(app.debugDescription)
            return
        }
        let frames = uniqueCardFrames(cards)
        for frame in frames { XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 2) }
        for _ in 0..<16 { scroll.swipeUp() }
        let searchButton = app.buttons["mural-search-button"]
        let last = try XCTUnwrap(uniqueCardFrames(cards).max(by: { $0.maxY < $1.maxY }))
        XCTAssertLessThanOrEqual(last.maxY, regular.exists ? app.frame.maxY : searchButton.frame.minY)
        searchButton.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.textFields["mural-search-field"].typeText("Camiseta")
        app.buttons["dismiss-mural-keyboard-button"].tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(cards.firstMatch.label.contains("Camiseta básica"))
        XCTAssertTrue(cards.firstMatch.label.contains("12,99"))
        XCTAssertTrue(cards.firstMatch.label.contains("Verde oliva"))
        XCTAssertTrue(app.buttons["mural-status-filter-menu"].isHittable)
        capture(app, "adaptive_mural_accessibility")
    }

    func testCompactMuralOptInAndNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Argument-domain defaults make both presentations deterministic,
        // independent of whichever preference the previous run persisted.
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "NO"]
        app.launch()
        guard app.descendants(matching: .any)["item-row"].firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Prueba de ancho compacto; ejecutar en iPhone vertical")
        }
        XCTAssertFalse(app.scrollViews["catalog-mural-compact"].exists)
        capture(app, "iphone_list_default")
        app.terminate()

        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES"]
        app.launch()
        XCTAssertTrue(app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["item-row"].exists)
        XCTAssertTrue(app.buttons["mural-status-filter-menu"].exists)
        XCTAssertTrue(app.buttons["mural-refresh-button"].exists)
        capture(app, "iphone_mural_opt_in")
        let card = app.descendants(matching: .any)["item-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["share-item-button"].waitForExistence(timeout: 5))
        capture(app, "iphone_mural_detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["start-selection-button"].waitForExistence(timeout: 5))
        app.buttons["start-selection-button"].tap()
        app.descendants(matching: .any)["item-card"].firstMatch.tap()
        XCTAssertTrue(app.buttons["share-selection-button"].isEnabled)
        capture(app, "iphone_mural_selection")
        app.buttons["end-selection-button"].tap()
        XCTAssertTrue(app.buttons["mural-status-filter-menu"].exists)
    }

    func testCompactMuralSettingsSwitch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Do not override this key through launch arguments here: the native
        // argument domain would mask writes made by the Settings toggle.
        app.launchArguments = ["--demo-catalog"]
        app.launch()
        app.tabBars.buttons["Ajustes"].tap()
        let toggle = app.switches["compact-catalog-mural-toggle"]
        // Settings has sections above Appearance; List materializes rows on scroll.
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        guard toggle.isEnabled else {
            throw XCTSkip("Switch compacto deshabilitado en ancho regular")
        }
        // SwiftUI exposes a row-sized switch container plus the native control.
        let control = toggle.switches.firstMatch
        if toggle.value as? String == "1" { control.tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        app.tabBars.buttons["Precios"].tap()
        guard app.descendants(matching: .any)["item-row"].firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Ejecutar en iPhone vertical")
        }
        app.tabBars.buttons["Ajustes"].tap()
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        control.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.tabBars.buttons["Precios"].tap()
        XCTAssertTrue(app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 5))
        capture(app, "iphone_mural_settings_enabled")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Ajustes"].tap()
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        control.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.tabBars.buttons["Precios"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["item-row"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "iphone_list_settings_disabled")
    }

    /// Geometry assertions distinguish a staggered mural from a two-column
    /// LazyVGrid. Run on an ordinary-width iPhone (e.g. 17 Pro) in portrait.
    func testCompactMuralStaggeredColumnsAndFloatingActions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"]
        app.launch()
        let scroll = app.scrollViews["catalog-mural-compact"]
        guard scroll.waitForExistence(timeout: 5), app.frame.width >= 358 else {
            throw XCTSkip("Dos columnas: iPhone compacto de al menos 358 pt")
        }
        let cards = app.descendants(matching: .any).matching(identifier: "item-card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let frames = uniqueCardFrames(cards)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let first = frames[0]
        let second = frames[1]
        XCTAssertGreaterThan(abs(first.midX - second.midX), 100)
        XCTAssertEqual(first.width, second.width, accuracy: 2)
        XCTAssertEqual(second.minY - first.minY, 52, accuracy: 2)
        capture(app, "iphone_gray_masonry_light")

        let searchButton = app.buttons["mural-search-button"]
        let refresh = app.buttons["mural-refresh-button"]
        let filter = app.buttons["mural-status-filter-menu"]
        let add = app.buttons["add-item-button"]
        for button in [searchButton, refresh, filter, add] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.tabBars.firstMatch.frame.minY)
        }
        XCTAssertLessThan(searchButton.frame.maxX, refresh.frame.minX)
        XCTAssertLessThan(refresh.frame.maxX, filter.frame.minX)
        XCTAssertLessThan(filter.frame.maxX, add.frame.minX)

        // Even at the bottom, the last card must be reachable above the controls.
        for _ in 0..<6 { scroll.swipeUp() }
        let finalFrames = uniqueCardFrames(cards)
        let last = try XCTUnwrap(finalFrames.max(by: { $0.maxY < $1.maxY }))
        XCTAssertLessThanOrEqual(last.maxY, searchButton.frame.minY)
        capture(app, "iphone_gray_masonry_last_card")
        searchButton.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let search = app.textFields["mural-search-field"]
        XCTAssertTrue(search.isHittable)
        search.typeText("Camiseta")
        app.buttons["dismiss-mural-keyboard-button"].tap()
        let match = cards.firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        XCTAssertTrue(match.label.contains("12,99"), "La tarjeta mantiene el precio real")
        XCTAssertTrue(match.label.contains("Verde oliva"))
        XCTAssertTrue(match.label.contains("Última comprobación correcta:"))
        XCTAssertTrue(app.buttons["mural-status-filter-menu"].isHittable)
        filter.tap()
        XCTAssertTrue(app.buttons["Pausados"].waitForExistence(timeout: 5))
        app.buttons["Pausados"].tap()
        XCTAssertTrue(app.staticTexts["Sin resultados"].waitForExistence(timeout: 5))
        filter.tap()
        app.buttons["Activos"].tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["Añadir producto"].waitForExistence(timeout: 5))
    }

    func testCompactMuralDarkTwoColumns() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES",
                               "-AppleInterfaceStyle", "Dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"]
        app.launch()
        guard app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 5), app.frame.width >= 358 else {
            throw XCTSkip("Ejecutar en iPhone compacto de al menos 358 pt")
        }
        let frames = uniqueCardFrames(app.descendants(matching: .any).matching(identifier: "item-card"))
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertGreaterThan(abs(frames[0].midX - frames[1].midX), 100)
        capture(app, "iphone_gray_masonry_dark")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])
    }

    /// On a narrow destination such as iPhone SE, normal text also gets one
    /// column rather than squeezing a title and currency into tiny tiles.
    func testCompactMuralNarrowWidthFallback() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM"]
        app.launch()
        guard app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 5), app.frame.width < 358 else {
            throw XCTSkip("Ejecutar en destino compacto menor de 358 pt")
        }
        let frames = uniqueCardFrames(app.descendants(matching: .any).matching(identifier: "item-card"))
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertEqual(frames[0].minX, frames[1].minX, accuracy: 2)
        XCTAssertGreaterThan(frames[0].width, app.frame.width * 0.8)
        capture(app, "iphone_gray_masonry_narrow_fallback")
    }

    private func uniqueCardFrames(_ query: XCUIElementQuery) -> [CGRect] {
        // Some OS versions expose both the link and its combined label with
        // the same identifier. Deduplicate frames without depending on type.
        query.allElementsBoundByIndex.reduce(into: [CGRect]()) { frames, element in
            let frame = element.frame
            if !frame.isEmpty && !frames.contains(frame) { frames.append(frame) }
        }
    }

    func testCompactMuralSearchKeyboardAndLargeText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog", "-compactCatalogMuralEnabled", "YES",
                               "-AppleInterfaceStyle", "Dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        guard app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Prueba de ancho compacto; ejecutar en iPhone vertical")
        }
        let frames = uniqueCardFrames(app.descendants(matching: .any).matching(identifier: "item-card"))
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        XCTAssertEqual(frames[0].minX, frames[1].minX, accuracy: 2)
        XCTAssertGreaterThan(frames[0].width, app.frame.width * 0.8)
        capture(app, "iphone_mural_dark_large_text")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])
        let search = app.textFields["mural-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zz_no_results_123")
        XCTAssertTrue(app.staticTexts["Sin resultados"].waitForExistence(timeout: 5))
        app.buttons["dismiss-mural-keyboard-button"].tap()
        XCTAssertTrue(app.buttons["mural-status-filter-menu"].waitForExistence(timeout: 5))
        app.buttons["Borrar búsqueda"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["item-card"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "iphone_mural_search_cleared")
    }

    private func firstItemElement(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["item-row"].firstMatch
        if row.exists { return row }
        return app.descendants(matching: .any)["item-card"].firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
