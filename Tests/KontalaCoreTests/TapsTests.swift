import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// What the core sends of a tap the platform read: a `click` row naming the control, once per control within the web's
/// window, never a disabled control's, and only while the app and the property capture taps.
final class TapsTests: XCTestCase {
    override func setUp() { Kontala.debugReset() }

    override func tearDown() { Kontala.debugReset() }

    private func session(_ options: KontalaOptions = KontalaOptions(), served: JSONObject? = contract2()) -> Session {
        let s = startKontala(options, served: served)
        Kontala.screen("/product/42")
        s.scheduler.runDue()
        return s
    }

    private let add = TapTarget(
        role: "button", declared: .addToCart, id: "add", text: "Add to bag", className: "UIButton ProductCard",
        path: "ProductViewController > ProductCard > UIButton#add", region: "main")

    private func tap(_ s: Session, _ p: Press) {
        s.onCore { $0.tapped(p) }
    }

    func testATapIsAClickRowNamingTheControlWhereItWas() {
        let s = session()
        tap(s, Press(add, control: RouteRef(self), input: "touch", x: 120.04, y: 330.26))
        s.sendAll()
        let click = s.collector.named("click").first
        XCTAssertEqual(
            ["role": "button", "id": "add", "text": "Add to bag", "class": "UIButton ProductCard"],
            click?.obj("element"))
        XCTAssertEqual("ProductViewController > ProductCard > UIButton#add", click?.str("path"))
        XCTAssertEqual("main", click?.str("region"))
        XCTAssertEqual("add_to_cart", click?.str("click_type"))
        XCTAssertEqual("touch", click?.str("input"))
        XCTAssertEqual(120.0, click?["x"]?.number, "to a tenth")
        XCTAssertEqual(330.3, click?["y"]?.number)
    }

    func testOneControlsRepeatedTapWithinTheWebsWindowIsOneAndAnotherControlsIsItsOwn() {
        let s = session()
        let control = RouteRef(self)
        tap(s, Press(add, control: control, input: "touch"))
        s.advanceMillis(300)
        tap(s, Press(add, control: control, input: "touch"))
        tap(s, Press(TapTarget(role: "button", text: "Size guide"), control: RouteRef(NSObject()), input: "touch"))
        s.advanceMillis(600)
        tap(s, Press(add, control: control, input: "touch"))
        s.sendAll()
        XCTAssertEqual(
            ["Add to bag", "Size guide", "Add to bag"],
            s.collector.named("click").map { $0.obj("element")!.str("text")! })
    }

    func testADisabledControlSendsNothing() {
        let s = session()
        tap(s, Press(TapTarget(role: "button", disabled: true, text: "Sold out"), control: nil, input: "touch"))
        s.sendAll()
        XCTAssertEqual([], s.collector.named("click"))
    }

    func testNothingIsSentWhereTheAppOrThePropertyCapturesNoTaps() {
        let off = session(KontalaOptions(taps: false))
        tap(off, Press(add, control: nil, input: "touch"))
        off.sendAll()
        XCTAssertEqual([], off.collector.named("click"), "the app's switch")
        Kontala.debugReset()

        let s = session(served: contract2(clicks: false))
        XCTAssertFalse(s.core.switches.tapsOn, "the main thread reads none")
        tap(s, Press(add, control: nil, input: "touch"))
        s.sendAll()
        XCTAssertEqual([], s.collector.named("click"), "the property's")
    }

    func testALoginsTapNamesWhoLogsInAndItsSubmitsAreItsRowsFromContract2() {
        let s = session()
        let form: JSONObject = ["fields": ["password"], "values": ["username": "anna@example.com"]]
        tap(
            s,
            Press(
                TapTarget(role: "button", text: "Log in"), control: nil, input: "touch", namedUser: "anna@example.com",
                submits: ["trigger": "click", "form": .object(form)]))
        s.sendAll()
        let click = s.collector.named("click").first
        XCTAssertEqual("anna@example.com", click?.str("user"))
        XCTAssertEqual("click", click?.str("trigger"))
        XCTAssertEqual(form, click?.obj("form"))
    }

    func testAtContract1ATapSendsNoneOfWhatContract2Adds() {
        let s = session(served: nil)
        tap(
            s,
            Press(
                TapTarget(role: "searchbox", label: "Search"), control: nil, input: "keyboard",
                submits: ["trigger": "submit", "search": "linen"]))
        s.sendAll()
        let click = s.collector.named("click").first
        XCTAssertNotNil(click)
        XCTAssertNil(click?["trigger"])
        XCTAssertNil(click?["search"])
    }
}
