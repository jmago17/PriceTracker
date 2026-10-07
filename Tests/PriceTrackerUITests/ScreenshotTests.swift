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

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
