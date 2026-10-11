import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        XCTAssertTrue(app.staticTexts["Comprobado ahora"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "catalog_fresh_after_equal_price")
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
        guard app.buttons["start-selection-button"].waitForExistence(timeout: 5) else {
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
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        guard toggle.isEnabled else {
            throw XCTSkip("Switch compacto deshabilitado en ancho regular")
        }
        if toggle.value as? String == "1" { toggle.tap() }
        app.tabBars.buttons["Precios"].tap()
        guard app.descendants(matching: .any)["item-row"].firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Ejecutar en iPhone vertical")
        }
        app.tabBars.buttons["Ajustes"].tap()
        toggle.tap()
        app.tabBars.buttons["Precios"].tap()
        XCTAssertTrue(app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 5))
        capture(app, "iphone_mural_settings_enabled")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.scrollViews["catalog-mural-compact"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Ajustes"].tap()
        app.switches["compact-catalog-mural-toggle"].tap()
        app.tabBars.buttons["Precios"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["item-row"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "iphone_list_settings_disabled")
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
