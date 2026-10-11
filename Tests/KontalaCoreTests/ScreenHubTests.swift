import XCTest

@testable import KontalaCore

/// The hub's own rules, the Flutter SDK's `NavigationHub` tests without Flutter's widgets.
final class ScreenHubTests: XCTestCase {
    private var starts: [NavigationKind] = []
    private var screens: [ScreenView] = []
    private var idles = 0
    private var logs: [String] = []
    private var hub: ScreenHub!

    override func setUp() {
        starts = []
        screens = []
        idles = 0
        logs = []
        hub = ScreenHub(
            onStart: { [unowned self] in self.starts.append($0) },
            onScreen: { [unowned self] in self.screens.append($0) },
            onIdle: { [unowned self] in self.idles += 1 },
            log: { [unowned self] in self.logs.append($0) })
    }

    func testTheFirstScreenIsTheLaunchWhateverItsSourceSaysAndANavigationIsToldOnce() {
        hub.start(foreground: true)
        hub.begin(.push)
        hub.begin(.pop)
        hub.shown("ShopViewController", .push)
        hub.begin(.pop)
        hub.shown("ShopViewController", .push)
        XCTAssertEqual([.push, .pop], starts)
        XCTAssertEqual([.launch, .pop], screens.map(\.kind))
    }

    func testAScreenNoNavigationBeganStartsNone() {
        hub.start(foreground: true)
        hub.shown("ShopViewController", .push)
        hub.shown("ShopViewController", .push)
        XCTAssertTrue(starts.isEmpty, "a screen shown again with no navigation")
        XCTAssertEqual(2, screens.count)
    }

    func testALinkMakesTheNextScreenALinkWithItsQuery() {
        hub.start(foreground: true)
        hub.shown("ShopViewController", .push)
        hub.linkPushed("kontalashop://shop/sale?utm_source=email&utm_campaign=autumn")
        hub.begin(.push)
        hub.shown("/sale", .push)
        let sale = screens.last!
        XCTAssertEqual(.link, sale.kind)
        XCTAssertEqual("utm_source=email&utm_campaign=autumn", sale.query)
        XCTAssertTrue(sale.link)
    }

    func testANavigationWhileTheAppIsHiddenIsHeldUntilItIsShownTheLatestAlone() {
        hub.start(foreground: true)
        hub.shown("ShopViewController", .push)
        hub.setForeground(false)
        hub.begin(.push)
        hub.shown("CartViewController", .push)
        hub.begin(.push)
        hub.shown("CheckoutViewController", .push)
        XCTAssertEqual(1, screens.count)
        hub.setForeground(true)
        XCTAssertEqual(["ShopViewController", "CheckoutViewController"], screens.map(\.name))
    }

    func testALaunchNothingNamesIsSlashAndALaterNamelessScreenIsNoneWithOneWarning() {
        hub.start(foreground: true)
        hub.launchCheck()
        XCTAssertEqual(["/"], screens.map(\.name))
        hub.begin(.push)
        hub.shown(nil, .push)
        hub.begin(.push)
        hub.shown(nil, .push)
        XCTAssertEqual(1, screens.count)
        XCTAssertEqual(2, idles)
        XCTAssertEqual(2, logs.count)
    }

    func testADeclaredNameWinsAndAPathIsSplitFromItsQuery() {
        hub.start(foreground: true)
        hub.shown("ProductViewController", .push, declaration: ScreenDeclaration(name: "/product/42?utm_source=feed"))
        XCTAssertEqual(["/product/42"], screens.map(\.name))
        XCTAssertEqual("utm_source=feed", screens.first?.query)
    }

    func testAScreenTheAppNamesIsAtOnceAndAfterTheLaunchAPush() {
        hub.start(foreground: true)
        hub.manual("/", nil)
        hub.manual("/cart", nil)
        XCTAssertEqual([.launch, .push], screens.map(\.kind))
        XCTAssertEqual([.launch, .push], starts)
    }

    func testANameIsReadAsAPathOrALinksAddressAndHeldToWhatTheApiTakes() {
        XCTAssertEqual(splitScreenName("kontalashop://shop/product/42?utm_source=push#reviews").0, "/product/42")
        XCTAssertEqual(splitScreenName("kontalashop://shop/product/42?utm_source=push").1, "utm_source=push")
        XCTAssertEqual(splitScreenName("app://only.host").0, "/")
        XCTAssertEqual(splitScreenName("/caf%C3%A9").0, "/café")
        XCTAssertEqual(splitScreenName("/50%").0, "/50%", "a path that does not decode is kept as it was written")
        XCTAssertEqual(splitScreenName("   ").0, "/")
        XCTAssertEqual(fillTemplate("product/{id}", ["id": "42"]), "product/42")
        XCTAssertEqual(fillTemplate("/product/:id?tab={tab}", ["id": "a b"]), "/product/a%20b")
        XCTAssertEqual(fillTemplate("product/{id}", [:]), "product/{id}")
    }
}
