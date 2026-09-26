//
//  FilmLibraryUITests.swift
//  Film CameraUITests
//

import XCTest

final class FilmLibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func openLibraryAndSearch(_ text: String) {
        app.buttons["Film Library"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(text)
    }

    private func assertStillRunning() {
        XCTAssertTrue(app.buttons["Take Photo"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Selecting a film while the search keyboard is up dismisses the sheet.
    func testSelectingFilmWhileSearchingDoesNotCrash() {
        openLibraryAndSearch("portra 400")
        let card = app.buttons["Kodak Portra 400"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        assertStillRunning()
    }
}
