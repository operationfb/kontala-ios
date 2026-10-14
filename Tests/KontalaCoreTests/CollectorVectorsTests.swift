import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// The collector's own vectors, which the tag's and the other SDKs' tests read too: a type the collector adds fails
/// this suite until the SDK has it.
final class CollectorVectorsTests: XCTestCase {
    private func codes(_ path: String, _ key: String) -> [String] {
        (repoJson(path).list(key) ?? []).map { $0.string! }
    }

    func testPageTypesAreTheCollectorsVocabularyInItsOrder() {
        XCTAssertEqual(
            codes("collector/pagesignals/testdata/vectors.json", "page_types"), KontalaPageType.allCases.map(\.wire))
    }

    func testClickTypesAreTheCollectorsVocabularyInItsOrder() {
        XCTAssertEqual(
            codes("collector/clicks/testdata/vectors.json", "click_types"), KontalaClickType.allCases.map(\.wire))
    }

    func testTheNamesACustomEventMayNotTakeAreTheApisReservedOnes() throws {
        let source = try String(
            contentsOf: repo.appendingPathComponent("collector/internal/api/build.go"), encoding: .utf8)
        let block = try NSRegularExpression(pattern: "var reserved = map\\[string\\]bool\\{([^}]*)\\}")
        let m = try XCTUnwrap(block.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let inner = String(source[Range(m.range(at: 1), in: source)!])
        let name = try NSRegularExpression(pattern: "\"([a-z_]+)\": true")
        let names = Set(
            name.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)).map {
                String(inner[Range($0.range(at: 1), in: inner)!])
            })
        XCTAssertEqual(names, reservedEventNames)
        XCTAssertEqual("page_view", canonicalEventName("Page View"))
        XCTAssertEqual("add_to_cart", canonicalEventName("add-to-cart!"))
    }

    private let friction = "collector/friction/testdata/vectors.json"
    private let scroll = "collector/scroll/testdata/vectors.json"

    private func cases(_ path: String, _ key: String) -> [JSONObject] {
        (repoJson(path).list(key) ?? []).compactMap(\.object)
    }

    func testAnErrorsNameIsOneARowMayCarry() {
        let limits = repoJson(friction).obj("limits")!
        XCTAssertEqual(limits.long("message"), Int64(Messages.maxMessage))
        XCTAssertEqual(limits.long("name"), Int64(Messages.maxName))
        for c in cases(friction, "names") {
            XCTAssertEqual(c["valid"]?.bool, Messages.validName(c.str("name")!), c.str("name")!)
        }
        for c in cases(friction, "name_of") {
            XCTAssertEqual(c.str("name"), Messages.nameOf(c.str("message")!), c.str("message")!)
        }
    }

    func testAMessageIsKeptAsTheCollectorKeepsItAndKeptAgainUnchanged() {
        for c in cases(friction, "normalize") {
            let got = Messages.normalizeMessage(c.str("name")!, c.str("message")!)
            XCTAssertEqual(c.str("want"), got, c.str("message")!)
            XCTAssertEqual(got, Messages.normalizeMessage(c.str("name")!, got))
        }
        for c in cases(friction, "ignored") {
            XCTAssertEqual(c["ignored"]?.bool, Messages.ignoredMessage(c.str("message")!), c.str("message")!)
        }
    }

    func testAnAppsSourceIsItsOwnCode() {
        for c in repoJson(friction).obj("app")!.list("sources")!.compactMap(\.object) {
            XCTAssertEqual(c["kept"]?.bool, Messages.appSource(c.str("source")!), c.str("source")!)
        }
        XCTAssertEqual(
            "ios:ShopApp/CartViewController", Messages.iosSource(module: "ShopApp", type: "CartViewController"))
        XCTAssertEqual(
            "ios:ShopApp", Messages.iosSource(module: "ShopApp", type: "Cart.ViewController"),
            "a type no row may carry leaves the module")
        XCTAssertEqual("ios:Shop-App.beta", Messages.iosSource(module: "Shop-App.beta", type: nil))
        XCTAssertNil(Messages.iosSource(module: "Shop App", type: "Cart"), "a module no row may carry names nothing")
    }

    func testASymbolNamesItsModuleAndTypeWhereItIsLiteral() {
        func parts(_ s: String) -> [String?]? { Messages.symbolParts(s).map { [$0.module, $0.type] } }
        XCTAssertEqual(["ShopApp", "CartViewController"], parts("$s7ShopApp18CartViewControllerC3payyyF"))
        XCTAssertEqual(
            ["ShopApp", "CartViewController"], parts("$s7ShopApp18CartViewControllerC3payyyFyycfU_"),
            "a closure in a method is its type's")
        XCTAssertEqual(["ShopApp", "Cart"], parts("_$s7ShopApp4CartV5totalSdvg"), "a struct's, with the C prefix")
        XCTAssertEqual(["ShopApp", nil], parts("$s7ShopApp8checkoutyyF"), "a global function is no type")
        XCTAssertEqual(["ShopApp", nil], parts("$s7ShopApp0A8DelegateC6windowSo8UIWindowCSgvg"), "nor an abbreviation")
        XCTAssertEqual([nil, "CartViewController"], parts("-[CartViewController pay:]"))
        XCTAssertEqual([nil, "ShopTheme"], parts("+[ShopTheme(Dark) apply]"), "a category's class")
        XCTAssertNil(parts("main"))
        XCTAssertNil(parts("__mh_execute_header"))
    }

    func testWhichSwipesAnAppSendsNeverOneThatMovedThePage() {
        XCTAssertEqual(repoJson(scroll).list("app_effects")!.map { $0.string! }, appEffects)
        for c in cases(scroll, "captured") {
            guard let effect = c.str("effect"), appEffects.contains(effect) else { continue }
            XCTAssertEqual(c["captured"]?.bool, swipeCaptured(c.str("direction")!, effect), "\(Json.encode(c))")
        }
        XCTAssertFalse(swipeCaptured("left", "page"))
    }
}
