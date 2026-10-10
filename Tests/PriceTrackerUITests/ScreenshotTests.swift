import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSyntheticCatalogAndDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog"]
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
        app.launchArguments = ["--demo-catalog"]
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
        app.launchArguments = ["--demo-catalog", "-AppleInterfaceStyle", "Dark",
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
        app.launchArguments = ["--demo-catalog", "--demo-history"]
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
        app.launchArguments = ["--demo-catalog", "--demo-history", "--demo-history-empty"]
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
        app.launchArguments = ["--demo-catalog"]
        app.launch()
        let item = firstItemElement(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Compartir"].waitForExistence(timeout: 5))
        capture(app, "context_menu_share")
    }

    func testSelectionShareBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-catalog"]
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
        app.launchArguments = ["--demo-catalog"]
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
        app.launchArguments = ["--demo-catalog"]
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
        app.launchArguments = ["--demo-catalog"]
        app.launch()
        guard app.buttons["start-selection-button"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Mural solo aparece en ancho regular (iPad)")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Camiseta básica"].waitForExistence(timeout: 5))
        capture(app, "mural_landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["Camiseta básica"].waitForExistence(timeout: 5))
        capture(app, "mural_portrait")
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
