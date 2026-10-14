import XCTest

/// A visit through the shop with real touches, for an end-to-end run against a local collector (README.md): the
/// carousel swiped, a product opened, added to the cart, a rage tap, a dead, a late and a disabled one, Delivery and
/// returns, a checkout, a login, a search from the keyboard, the app to the background and back, and the size guide's
/// exception, sent by the next launch. It asserts what the app shows; what was sent is read from the collector.
final class ShopVisitUITests: XCTestCase {
    private func centre(_ e: XCUIElement) -> XCUICoordinate {
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    private func drag(_ e: XCUIElement, from: CGVector, to: CGVector) {
        e.coordinate(withNormalizedOffset: from).press(
            forDuration: 0.01, thenDragTo: e.coordinate(withNormalizedOffset: to), withVelocity: .fast,
            thenHoldForDuration: 0)
    }

    /// Back to home, however many screens away it is.
    private func home(_ app: XCUIApplication) {
        for _ in 0..<5 where !app.buttons["search"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
    }

    /// Three and a half minutes on Delivery and returns and back, for a build with a short visit
    /// (`KONTALA_SESSION_MINUTES=2`): the page's activity keeps the app's visit, so home is shown in the same session.
    /// Run alone, with `-only-testing:KontalaShopUITests/ShopVisitUITests/testThePageKeepsTheAppsVisit`.
    func testThePageKeepsTheAppsVisit() throws {
        let app = XCUIApplication()
        app.launch()
        let shirt = app.staticTexts["Linen shirt"]
        XCTAssertTrue(shirt.waitForExistence(timeout: 15))
        shirt.tap()
        let delivery = app.buttons["Delivery and returns"]
        XCTAssertTrue(delivery.waitForExistence(timeout: 5))
        delivery.tap()
        // The page's own route changes, every 50 seconds: its activity, which slides the app's visit.
        let routes = ["Size guide (pushState)", "Back to the top"]
        XCTAssertTrue(app.webViews.buttons[routes[0]].waitForExistence(timeout: 15))
        for i in 0..<4 {
            sleep(50)
            app.webViews.buttons[routes[i % 2]].tap()
        }
        sleep(10)
        home(app)
        sleep(5)
    }

    func testAVisitThroughTheShop() {
        let app = XCUIApplication()
        app.launch()
        let campaigns = app.staticTexts["Autumn edit"]
        XCTAssertTrue(campaigns.waitForExistence(timeout: 15))
        sleep(2)
        drag(campaigns, from: CGVector(dx: 0.85, dy: 0.5), to: CGVector(dx: 0.15, dy: 0.5))
        sleep(1)

        app.staticTexts["Linen shirt"].tap()
        let add = app.buttons["Add to cart"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        sleep(2)
        add.tap()
        XCTAssertTrue(app.staticTexts["1 in your cart"].waitForExistence(timeout: 2))
        sleep(1)
        let compare = app.buttons["Compare"]
        for _ in 0..<3 { centre(compare).tap() }
        sleep(9)
        centre(app.buttons["Notify me when XL is back"]).tap()
        sleep(2)
        app.buttons["Check delivery date"].tap()
        XCTAssertTrue(app.staticTexts["Arrives on Thursday"].waitForExistence(timeout: 6))
        sleep(5)
        let page = app.scrollViews.firstMatch
        drag(page, from: CGVector(dx: 0.92, dy: 0.8), to: CGVector(dx: 0.92, dy: 0.2))
        sleep(2)
        app.buttons["Delivery and returns"].tap()
        sleep(8)
        home(app)

        app.buttons["cart"].tap()
        app.buttons["Checkout"].tap()
        let name = app.textFields["Full name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Anna de Vries")
        app.textFields["Postcode"].tap()
        app.textFields["Postcode"].typeText("1011 AB")
        app.textFields["Card number"].tap()
        app.textFields["Card number"].typeText("4242424242424242")
        app.buttons["Pay £79.00"].tap()
        XCTAssertTrue(app.staticTexts["Thank you"].waitForExistence(timeout: 5))
        sleep(1)
        app.buttons["Keep shopping"].tap()
        sleep(1)
        home(app)

        app.buttons["account"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("anna@example.com")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("not sent")
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["anna@example.com"].waitForExistence(timeout: 3))
        home(app)

        app.buttons["search"].tap()
        let box = app.textFields["Search the shop"]
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        box.typeText("linen\n")
        let result = app.buttons["Linen shirt"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        sleep(1)
        result.tap()
        sleep(2)

        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        sleep(3)

        // An exception nothing catches ends the app; the next launch sends it.
        app.buttons["Size guide"].tap()
        sleep(3)
        app.launch()
        XCTAssertTrue(campaigns.waitForExistence(timeout: 15))
        sleep(8)
    }
}
