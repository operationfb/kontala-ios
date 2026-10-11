import Foundation
import XCTest

@testable import KontalaCore

/// The public API as an app calls it, the Flutter SDK's public tests without the taps, which arrive with a later phase.
final class PublicTests: XCTestCase {
    private var dirs: [String] = []

    override func setUp() { Kontala.debugReset() }

    override func tearDown() {
        Kontala.debugReset()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs.removeAll()
    }

    private func tempDir() -> String {
        let d = temporaryDirectory()
        dirs.append(d)
        return d
    }

    /// The launch's first frame, with no screen named: the launch is filed as `/`.
    private func launch(_ s: Session) {
        s.firstFrame()
        s.advanceMillis(1000)
    }

    private struct AppBug: Error {}

    func testUnknownHoldsEveryEventUntilTheAnswerThenSendsThemAsGranted() {
        let s = startKontala(KontalaOptions(consent: .unknown))
        launch(s)
        Kontala.track("tapped_go")
        s.advanceMillis(2000)
        s.sendAll()
        XCTAssertTrue(s.collector.events.isEmpty)
        Kontala.consent(.granted)
        s.sendAll()
        XCTAssertEqual(Set(["granted"]), Set(s.collector.events.compactMap { $0.str("consent") }))
        XCTAssertEqual(1, s.collector.named("tapped_go").count)
    }

    func testDeniedSendsScreenViewsAsDeniedAndWritesNothing() {
        let dir = tempDir()
        let s = startKontala(KontalaOptions(consent: .denied), facts: testFacts(storageDir: dir))
        launch(s)
        s.sendAll()
        XCTAssertEqual(["denied"], s.collector.named("page_view").map { $0.str("consent")! })
        let files = FileManager.default.enumerator(atPath: dir + "/kontala")?.allObjects as? [String] ?? []
        let written = files.filter {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: dir + "/kontala/" + $0, isDirectory: &isDir)
            return !isDir.boolValue
        }
        XCTAssertEqual([], written)
    }

    func testHeldEventsLeaveAsUnknownWhenTheAppIsHidden() {
        let s = startKontala(KontalaOptions(consent: .unknown))
        launch(s)
        s.advanceMillis(500)
        s.lifecycle(.inactive)
        s.lifecycle(.hidden)
        s.sendAll()
        XCTAssertEqual(["unknown"], s.collector.named("page_view").map { $0.str("consent")! })
    }

    func testIdentifyStampsEveryLaterEventAndItsTraitsAreSentOnce() {
        Kontala.identify(user: "u-1", org: "acme", traits: ["plan": "pro"])
        let s = startKontala()
        launch(s)
        Kontala.track("upgrade_viewed", properties: ["from": "settings"])
        Kontala.identify()
        Kontala.track("signed_out")
        s.sendAll()
        XCTAssertEqual([["plan": "pro"] as JSONObject], s.collector.named("identify").map { $0.obj("properties")! })
        let upgrade = s.collector.named("upgrade_viewed")[0]
        XCTAssertEqual("u-1", upgrade.str("user"))
        XCTAssertEqual("acme", upgrade.str("org"))
        XCTAssertEqual(["from": "settings"] as JSONObject, upgrade.obj("properties"))
        XCTAssertEqual(
            "u-1", s.collector.named("page_view").first?.str("user"), "calls before the first screen ride on it")
        XCTAssertNil(s.collector.named("signed_out").first?["user"])
    }

    func testANameKontalaGivesItsOwnEventsIsRefusedInAnySpelling() {
        let s = startKontala()
        launch(s)
        Kontala.track("Page View")
        Kontala.track("purchase")
        Kontala.track("wishlisted")
        s.sendAll()
        XCTAssertEqual(
            ["wishlisted"],
            s.collector.events.compactMap { $0.str("event") }.filter { $0 != "page_view" && $0 != "app_opened" })
    }

    func testResetStartsANewDeviceAndSessionOptingOutStopsEverythingAndPersists() throws {
        let dir = tempDir()
        let s = startKontala(facts: testFacts(storageDir: dir))
        launch(s)
        Kontala.track("before")
        Kontala.reset()
        Kontala.track("after")
        s.sendAll()
        let before = s.collector.named("before")[0]
        let after = s.collector.named("after")[0]
        XCTAssertNotEqual(before.str("device"), after.str("device"))
        XCTAssertNotEqual(before.str("session"), after.str("session"))

        Kontala.optOut(true)
        Kontala.track("ignored")
        s.sendAll()
        XCTAssertTrue(s.collector.named("ignored").isEmpty)
        let meta = Json.decodeObject(try Data(contentsOf: URL(fileURLWithPath: dir + "/kontala/meta.json")))!
        XCTAssertEqual(.bool(true), meta["opted_out"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/kontala/identity.json"))
        XCTAssertTrue(Kontala.isOptedOut)
    }

    func testBeforeSendEditsAndDropsAndOneThatThrowsDropsItsEvent() {
        let s = startKontala(
            KontalaOptions(beforeSend: { e in
                switch e.name {
                case "secret": return nil
                case "broken": throw AppBug()
                default:
                    var edited = e
                    edited.properties?.removeValue(forKey: "email")
                    return edited
                }
            }))
        launch(s)
        Kontala.track("secret")
        Kontala.track("broken")
        Kontala.track("kept", properties: ["email": "anna@example.com", "plan": "pro"])
        s.sendAll()
        XCTAssertEqual(["plan": "pro"] as JSONObject, s.collector.named("kept").first?.obj("properties"))
        XCTAssertTrue(s.collector.named("secret").isEmpty)
        XCTAssertTrue(s.collector.named("broken").isEmpty)
    }

    func testTheInstallComesBeforeTheOpen() {
        let dir = tempDir()
        let s = startKontala(facts: testFacts(storageDir: dir))
        launch(s)
        s.advanceMillis(3000)
        s.sendAll()
        XCTAssertEqual(["page_view", "app_installed", "app_opened"], s.collector.events.compactMap { $0.str("event") })
    }

    func testAFirstLaunchIsAnInstallANewVersionAnUpdateAndEachOpenAndCloseIsTold() {
        let dir = tempDir()
        var s = startKontala(facts: testFacts(storageDir: dir))
        launch(s)
        s.advanceMillis(5000)
        s.lifecycle(.inactive)
        s.lifecycle(.hidden)
        s.advanceMillis(3000)
        s.lifecycle(.inactive)
        s.lifecycle(.resumed)
        s.sendAll()
        let view = s.collector.named("page_view")[0]
        let installed = s.collector.named("app_installed")
        XCTAssertEqual(1, installed.count)
        XCTAssertEqual(["version": "3.2.0", "build": "412"] as JSONObject, installed[0].obj("properties"))
        XCTAssertEqual(view.str("id"), installed[0].str("view"), "filed under the launch screen")
        XCTAssertEqual(["cold": true] as JSONObject, s.collector.named("app_opened").first?.obj("properties"))
        let foreground = s.collector.named("app_backgrounded")[0].obj("properties")!.long("foreground_ms")!
        XCTAssertGreaterThanOrEqual(foreground, 5000)
        XCTAssertEqual(
            ["cold": false, "away_ms": 3000] as JSONObject, s.collector.named("app_opened").last?.obj("properties"))
        XCTAssertEqual(1, s.platform.tasksBegun, "the hide's flush held a background task")
        XCTAssertEqual([1], s.platform.tasksEnded, "and let it go once the flush was done")
        s.finish()

        var facts = testFacts(storageDir: dir)
        facts.appVersion = "3.3.0"
        facts.appBuild = "420"
        s = startKontala(facts: facts)
        launch(s)
        s.sendAll()
        XCTAssertEqual(
            ["version": "3.3.0", "build": "420", "previous_version": "3.2.0", "previous_build": "412"] as JSONObject,
            s.collector.named("app_updated").first?.obj("properties"))
        XCTAssertTrue(s.collector.named("app_installed").isEmpty)
        XCTAssertEqual(view.str("device"), s.collector.named("page_view").first?.str("device"), "the same install")
    }

    func testAScreenTheAppNamesIsAPageViewOfItsPathWithItsLinksQuery() {
        let s = startKontala()
        Kontala.screen("/?utm_source=push&utm_campaign=autumn")
        s.firstFrame()
        s.advanceMillis(1000)
        Kontala.screen("/product/42", pageType: .productDetail, properties: ["product_id": "42"])
        s.advanceMillis(1000)
        s.sendAll()
        let views = s.collector.named("page_view")
        XCTAssertEqual(
            [
                ["name": "/", "query": "utm_source=push&utm_campaign=autumn"] as JSONObject,
                ["name": "/product/42"] as JSONObject,
            ], views.map { $0.obj("screen")! })
        XCTAssertEqual("pdp", views[1].str("page_type"))
        XCTAssertEqual(["product_id": "42"] as JSONObject, views[1].obj("properties"))
    }

    func testAnAppsPropertiesAreSentInTheirKeysOrderAndWhatIsNotJsonIsLeftOut() {
        let s = startKontala(KontalaOptions(debug: true))
        launch(s)
        struct Opaque {}
        enum Size: String { case medium = "M" }
        Kontala.track(
            "chosen",
            properties: [
                "z": 1, "a": Size.medium, "when": Date(timeIntervalSince1970: 1_791_191_702),
                "opaque": Opaque(), "none": Optional<String>.none as Any, "list": [1, 2.5, "x"],
                "nested": ["b": true, "a": Float(0.1)],
            ])
        s.sendAll()
        let p = s.collector.named("chosen")[0].obj("properties")!
        XCTAssertEqual(p.keys, ["a", "list", "nested", "none", "when", "z"])
        XCTAssertEqual(p["a"], "M")
        XCTAssertEqual(p["when"], "2026-10-05T09:15:02.000000Z")
        XCTAssertEqual(p["none"], .null)
        XCTAssertEqual(p["list"], [1, 2.5, "x"])
        XCTAssertEqual(p["nested"], ["a": 0.1, "b": true])
        XCTAssertTrue(s.platform.lines.contains { $0.contains("a property of type Opaque is not JSON") })
    }
}
