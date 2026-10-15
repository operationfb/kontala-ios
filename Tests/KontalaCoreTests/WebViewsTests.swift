import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// The websites an app shows in a web view, and the app, as one visitor and one visit: the Flutter SDK's
/// `test/webviews_test.dart` and the Android SDK's `WebViewsTest`, case for case, on the core with a fake cookie store
/// and a fake web view.
final class WebViewsTests: XCTestCase {
    private var dir = ""

    override func setUp() {
        Kontala.debugReset()
        dir = temporaryDirectory()
    }

    override func tearDown() {
        Kontala.debugReset()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private let shop = "https://shop.example.com"

    /// The challenge a page's hello sends, which the app's answer echoes.
    private let challenge = "5b8f2c1e-9d3a-4e7b-8c6f-1a2b3c4d5e6f"

    /// A page with the tag on it saying hello.
    private var hello: String { #"{"kontala":1,"type":"hello","challenge":"\#(challenge)"}"# }

    private func activity(_ nonce: String, _ s: WebSession) -> String {
        #"{"kontala":1,"type":"activity","nonce":"\#(nonce)","session":"\#(s.id)","last_seen":\#(s.lastSeen)}"#
    }

    private func start(_ options: KontalaOptions? = nil, cookies: FakeCookieStore? = FakeCookieStore()) -> Session {
        let s = startKontala(
            options ?? KontalaOptions(webOrigins: [shop]), facts: testFacts(storageDir: dir), served: contract2(),
            cookies: cookies)
        // The launch's screen, as the app opens on it.
        Kontala.screen("/")
        s.scheduler.runDue()
        return s
    }

    /// A launch whose configuration waits until the test releases it, as a slow network keeps it, from a region on
    /// contract 2 whose property shows the shop in its web views (`web_views`).
    private func firstLaunch(_ store: FakeCookieStore, _ options: KontalaOptions = KontalaOptions()) -> Session {
        var served = contract2()
        served["web_views"] = ["origins": .array([.object(["origin": .string(shop)])])]
        let s = startKontala(
            options, facts: testFacts(storageDir: dir), served: served, cookies: store, holdConfig: true)
        Kontala.screen("/")
        s.scheduler.runDue()
        return s
    }

    /// Whether the websites have the app's ids yet.
    private func ready(_ s: Session) -> Bool {
        var done = false
        Kontala.webViewsReady { done = true }
        s.scheduler.runDue()
        return done
    }

    /// A navigation to the size guide, whose screen shows [webView], attached as the screen is built.
    @discardableResult
    private func sizeGuide(_ s: Session, _ webView: FakeWebView? = nil) -> WebAttachment? {
        var a: WebAttachment?
        s.onCore { core in
            core.hub.begin(.push)
            a = webView.map { core.attachWebView($0) }
            core.hub.shown("/size-guide", .push)
        }
        return a
    }

    /// Back to the shop's front page.
    private func back(_ s: Session) {
        s.onCore { core in
            core.hub.begin(.pop)
            core.hub.shown("/", .pop)
        }
    }

    private func attach(_ s: Session, _ webView: FakeWebView) -> WebAttachment {
        var a: WebAttachment?
        s.onCore { a = $0.attachWebView(webView) }
        return a!
    }

    private func receive(_ s: Session, _ a: WebAttachment, _ message: String) {
        s.onCore { _ in a.receive(message) }
    }

    private func screens(_ s: Session) -> [String] {
        s.collector.named("page_view").map { $0.obj("screen")!.str("name")! }
    }

    // The cookie handover.

    func testGivesTheWebsitesTheAppShowsItsIdsAsTheTagWritesThem() {
        let store = FakeCookieStore()
        let s = start(KontalaOptions(webOrigins: [shop, "http://localhost:4173", "not an origin"]), cookies: store)
        XCTAssertTrue(ready(s))
        s.sendAll()

        let view = s.collector.named("page_view").first!
        XCTAssertEqual(s.collector.named("page_view").count, 1)
        XCTAssertEqual(view.str("device"), store.byUrl["\(shop)/"]?[WebViews.deviceCookie])
        XCTAssertEqual(view.str("session"), store.session("\(shop)/")?.id)
        XCTAssertEqual(view.str("session"), store.session("http://localhost:4173/")?.id)
        let header = store.writes.first { $0.url == "\(shop)/" && $0.name == WebViews.deviceCookie }!.header
        XCTAssertEqual("pt_did=\(view.str("device")!); Max-Age=63072000; Path=/; SameSite=Lax; Secure", header)
        XCTAssertFalse(store.byUrl.keys.contains { $0.contains("not an origin") })
        s.finish()
    }

    func testAFirstLaunchIsReadyAtOnceAndGivesTheWebsitesItsConfigurationNamesTheIdsAsItAnswers() {
        let store = FakeCookieStore()
        // Nothing is kept yet and the options name no website: which websites the app shows is the configuration's to
        // say, which a slow network holds back.
        let s = firstLaunch(store)
        XCTAssertTrue(ready(s))
        XCTAssertTrue(store.writes.isEmpty)
        s.collector.releaseConfig()
        s.scheduler.runDue()
        s.sendAll()

        XCTAssertEqual(s.collector.named("page_view").count, 1)
        let view = s.collector.named("page_view").first!
        XCTAssertEqual(view.str("device"), store.byUrl["\(shop)/"]?[WebViews.deviceCookie])
        XCTAssertEqual(view.str("session"), store.session("\(shop)/")?.id)
        s.finish()
    }

    func testAWebViewOnShowIsReadBackOnceALateConfigurationNamesItsWebsite() {
        let s = firstLaunch(FakeCookieStore(), KontalaOptions(debug: true))
        XCTAssertTrue(ready(s))
        // The visitor opens a web view before the configuration has answered.
        s.platform.webViewOnShow = true
        sizeGuide(s)
        let polling = "[kontala] a web view is on show: its pages' visit is read back every minute"
        XCTAssertFalse(s.platform.lines.contains(polling))
        s.collector.releaseConfig()
        s.scheduler.runDue()
        XCTAssertTrue(s.platform.lines.contains(polling))
        s.finish()
    }

    func testALaunchThatKnowsItsWebsitesFromItsOptionsOrKeptWritesTheIdsBeforeItIsReady() {
        let store = FakeCookieStore()
        var s = firstLaunch(store, KontalaOptions(webOrigins: [shop]))
        XCTAssertTrue(ready(s))
        XCTAssertNotNil(store.session("\(shop)/"))
        s.collector.releaseConfig()
        s.scheduler.runDue()
        s.finish()

        // The next launch names no website, but kept the configuration the first one read.
        store.writes.removeAll()
        s = firstLaunch(store)
        XCTAssertTrue(ready(s))
        XCTAssertFalse(store.writes.isEmpty)
        s.collector.releaseConfig()
        s.scheduler.runDue()
        s.finish()
    }

    func testAPagesLaterActivityKeepsTheAppsVisitAlive() {
        let store = FakeCookieStore()
        let s = start(KontalaOptions(sessionTimeout: 60, webOrigins: [shop]), cookies: store)
        XCTAssertTrue(ready(s))
        let first = store.session("\(shop)/")!
        // A web view the app did not attach: the cookies are all there is.
        s.platform.webViewOnShow = true
        sizeGuide(s)

        // The visitor reads the page for 50 seconds, which its tag writes, and the app reads back while the web view
        // is on show.
        s.advanceMillis(50_000)
        store.byUrl["\(shop)/"]![WebViews.sessionCookie] = WebSession(first.id, first.lastSeen + 50_000).value
        s.advanceMillis(15_000)
        // Back in the app, past its own minute since its last event, but not since the page's.
        s.platform.webViewOnShow = false
        back(s)
        s.sendAll()

        XCTAssertEqual(Set([first.id]), Set(s.collector.events.compactMap { $0.str("session") }))
        XCTAssertEqual(["/", "/size-guide", "/"], screens(s))
        s.finish()
    }

    func testAVisitAPageStartedAfterTheAppsHadLapsedIsTheApps() {
        let store = FakeCookieStore()
        let s = start(KontalaOptions(sessionTimeout: 60, webOrigins: [shop]), cookies: store)
        XCTAssertTrue(ready(s))
        let first = store.session("\(shop)/")!
        s.platform.webViewOnShow = true
        sizeGuide(s)

        // The visitor sits on the page past the minute, and the page starts a visit of its own as they read on, 110
        // seconds in.
        s.advanceMillis(110_000)
        let own = WebSession("page-visit", first.lastSeen + 110_000)
        store.byUrl["\(shop)/"]![WebViews.sessionCookie] = own.value
        s.advanceMillis(15_000)
        s.platform.webViewOnShow = false
        back(s)
        s.sendAll()

        XCTAssertEqual(own.id, s.collector.named("page_view").last?.str("session"))
        s.finish()
    }

    func testWritesNothingWithoutConsentAndDeletesTheCookiesWhenItGoes() {
        let store = FakeCookieStore()
        let s = start(cookies: store)
        XCTAssertTrue(ready(s))
        XCTAssertFalse(store.byUrl["\(shop)/"]!.isEmpty)

        Kontala.consent(.denied)
        s.scheduler.runDue()
        XCTAssertTrue(store.byUrl["\(shop)/"]!.isEmpty)
        let deleted = Set(store.writes.filter { $0.maxAgeSeconds == 0 }.map(\.name))
        XCTAssertEqual(Set([WebViews.deviceCookie, WebViews.sessionCookie]), deleted)

        // Nothing is written again while consent is not granted.
        let before = store.writes.count
        sizeGuide(s)
        XCTAssertEqual(before, store.writes.count)
        s.finish()
    }

    func testAnAppThatForgetsItsVisitorGivesTheWebsitesNewIds() {
        let store = FakeCookieStore()
        let s = start(cookies: store)
        XCTAssertTrue(ready(s))
        let device = store.byUrl["\(shop)/"]![WebViews.deviceCookie]

        Kontala.reset()
        s.scheduler.runDue()
        sizeGuide(s)
        XCTAssertNotEqual(device, store.byUrl["\(shop)/"]![WebViews.deviceCookie])
        XCTAssertNotNil(store.byUrl["\(shop)/"]![WebViews.deviceCookie])
        s.finish()
    }

    func testWithNoWebsitesNothingIsWrittenAndTheWebViewsAreReadyAtOnce() {
        let store = FakeCookieStore()
        let s = start(KontalaOptions(), cookies: store)
        XCTAssertTrue(ready(s))
        XCTAssertTrue(store.writes.isEmpty)
        s.finish()
    }

    // The bridge.

    func testTellsAPageOnOneOfTheWebsitesTheAppsContextWithANonce() {
        Kontala.identify(user: "anna@example.com")
        let s = start()
        let webView = FakeWebView(url: "\(shop)/size-guide")
        let attachment = attach(s, webView)
        receive(s, attachment, hello)
        s.sendAll()

        let view = s.collector.named("page_view").first!
        XCTAssertEqual(webView.contexts.count, 1)
        let context = webView.contexts[0]
        XCTAssertEqual(1, context.long("v"))
        XCTAssertEqual(challenge, context.str("challenge"))
        let nonce = context.str("nonce")!
        XCTAssertTrue(nonce.count >= 16)
        XCTAssertEqual(view.str("device"), context.str("device"))
        XCTAssertEqual(view.str("session"), context.str("session"))
        XCTAssertNotNil(context.long("last_seen"))
        XCTAssertEqual("granted", context.str("consent"))
        XCTAssertFalse(context.contains("consent_signals"), "none recorded where no section is served")
        XCTAssertEqual("anna@example.com", context.str("user"))
        XCTAssertEqual(
            [
                "id": "com.example.shop", "version": "3.2.0", "build": "412", "mode": "debug", "sdk": "kontala-ios",
                "sdk_version": .string(sdkVersion),
            ] as JSONObject, context.obj("app"))
        XCTAssertTrue(webView.scripts[0].hasPrefix("(function(){if(location.origin!==\"\(shop)\")return;"))
        s.finish()
    }

    func testAnswersNoPageOnAnotherWebsiteAndNoMessageWithoutItsNonce() {
        let s = start()
        let webView = FakeWebView(url: "https://elsewhere.example.org/")
        let attachment = attach(s, webView)
        receive(s, attachment, hello)
        XCTAssertTrue(webView.scripts.isEmpty)

        webView.url = "\(shop)/"
        receive(s, attachment, hello)
        XCTAssertEqual(1, webView.scripts.count)
        receive(s, attachment, #"{"kontala":1,"type":"identify","nonce":"b3RoZXJmcmFtZW5vbmNlMDA","user":"mallory"}"#)
        sizeGuide(s)
        s.sendAll()
        XCTAssertNil(s.collector.named("page_view").last?["user"])
        s.finish()
    }

    func testTakesAPagesActivityAndItsOwnSignInWhereTheAppNamesNobody() {
        let s = start(KontalaOptions(sessionTimeout: 60, webOrigins: [shop]))
        let webView = FakeWebView(url: "\(shop)/")
        let attachment = attach(s, webView)
        receive(s, attachment, hello)
        let context = webView.contexts[0]
        let nonce = context.str("nonce")!
        let session = context.str("session")!
        let seen = context.long("last_seen")!

        // The page is read for 50 seconds, and says so; 20 seconds later the app's own minute has gone, the page's
        // not.
        s.advanceMillis(50_000)
        receive(s, attachment, activity(nonce, WebSession(session, seen + 50_000)))
        receive(s, attachment, #"{"kontala":1,"type":"identify","nonce":"\#(nonce)","user":"web-user"}"#)
        s.advanceMillis(20_000)
        sizeGuide(s)
        s.sendAll()

        let last = s.collector.named("page_view").last!
        XCTAssertEqual(session, last.str("session"))
        XCTAssertEqual("web-user", last.str("user"))
        s.finish()
    }

    func testTellsAPageHoldingAnotherVisitTheApps() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/")
        let attachment = attach(s, webView)
        receive(s, attachment, hello)
        let context = webView.contexts[0]
        receive(
            s, attachment,
            activity(context.str("nonce")!, WebSession("the-pages-own", context.long("last_seen")! + 1000)))
        XCTAssertEqual(context.str("session"), webView.contexts.last?.str("session"))
        XCTAssertEqual(2, webView.contexts.count)
        // An update the page takes by the nonce of its first context.
        XCTAssertNil(webView.contexts.last?["challenge"])
        XCTAssertEqual(context.str("nonce"), webView.contexts.last?.str("nonce"))
        s.finish()
    }

    func testAnswersEachHelloWithItsOwnChallengeAFramesInsideThePageAmongThem() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/")
        let attachment = attach(s, webView)
        // A frame inside the page can reach the channel too; its hello must not take the place of the page's,
        // whichever comes first.
        receive(s, attachment, hello)
        receive(s, attachment, #"{"kontala":1,"type":"hello","challenge":"7c1d9e2f-3a4b-4c5d-8e6f-a1b2c3d4e5f6"}"#)
        XCTAssertEqual(
            [challenge, "7c1d9e2f-3a4b-4c5d-8e6f-a1b2c3d4e5f6"], webView.contexts.map { $0.str("challenge") })
        // An older tag's hello says no challenge, and is answered echoing none; one whose challenge is not of the
        // protocol is no hello.
        receive(s, attachment, #"{"kontala":1,"type":"hello"}"#)
        receive(s, attachment, #"{"kontala":1,"type":"hello","challenge":"short"}"#)
        XCTAssertEqual(3, webView.contexts.count)
        XCTAssertNil(webView.contexts.last?["challenge"])
        s.finish()
    }

    func testGivesAPageAPinnedSessionWithWhenItWasLastActive() {
        let store = FakeCookieStore()
        let s = start(KontalaOptions(sessionId: "pinned-session", webOrigins: [shop]), cookies: store)
        let webView = FakeWebView(url: "\(shop)/")
        receive(s, attach(s, webView), hello)
        // The tag takes no context, and reads no cookie, whose last activity is 0: it would be a visit that lapsed
        // in 1970.
        let context = webView.contexts[0]
        XCTAssertEqual("pinned-session", context.str("session"))
        XCTAssertGreaterThan(context.long("last_seen") ?? 0, 0)
        XCTAssertEqual(WebSession("pinned-session", context.long("last_seen") ?? 0), store.session("\(shop)/"))
        s.finish()
    }

    func testTellsAnAnsweredPageWhatTheVisitorAnsweredInAConsentManagerAsItChanges() {
        let s = startKontala(
            KontalaOptions(webOrigins: [shop]), facts: testFacts(storageDir: dir), served: contract3(),
            cookies: FakeCookieStore(), tcf: tcfMeasureOnly)
        Kontala.screen("/")
        s.scheduler.runDue()
        let webView = FakeWebView(url: "\(shop)/")
        receive(s, attach(s, webView), hello)
        Kontala.setConsentSignals(targeting: true)
        s.scheduler.runDue()
        XCTAssertEqual(["granted", "granted"], webView.contexts.map { $0.str("consent")! })
        XCTAssertEqual(
            [
                [
                    "functional": false, "analytics": true, "targeting": false, "source": "tcf", "status": "ready",
                    "decided": true,
                ],
                [
                    "functional": false, "analytics": true, "targeting": true, "source": "app", "status": "ready",
                    "decided": true,
                ],
            ],
            webView.contexts.map { $0.obj("consent_signals") })
        s.finish()
    }

    func testTellsAnAnsweredPageWhenConsentChanges() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/")
        receive(s, attach(s, webView), hello)
        Kontala.consent(.denied)
        s.scheduler.runDue()
        XCTAssertEqual(["granted", "denied"], webView.contexts.map { $0.str("consent")! })
        XCTAssertEqual([challenge, nil], webView.contexts.map { $0.str("challenge") })
        s.finish()
    }

    func testADetachedWebViewIsAnsweredNoMore() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/")
        let attachment = attach(s, webView)
        s.onCore { _ in attachment.detach() }
        receive(s, attachment, hello)
        XCTAssertTrue(webView.scripts.isEmpty)
        s.finish()
    }

    // A screen showing an attached web view.

    func testIsNoScreenViewOfItsOwnOnceItsPageAnswers() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/size-guide", coverage: 1)
        let attachment = sizeGuide(s, webView)!
        // The page loads and says hello, within the screen view's wait.
        s.advanceMillis(2_000)
        receive(s, attachment, hello)
        // The app's own event on the screen, such as its toolbar's share.
        Kontala.track("shared")
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/"], screens(s))
        let shared = s.collector.named("shared")
        XCTAssertEqual(shared.count, 1)
        XCTAssertNil(shared[0]["view"], "what the screen's own toolbar did is filed under no view")
        XCTAssertEqual(["screen": "/size-guide"] as JSONObject, shared[0].obj("context")?.obj("app"))
        let front = s.collector.named("page_view")[0].str("id")
        XCTAssertTrue(s.collector.events.allSatisfy { $0.str("event") != "view_time" || $0.str("view") == front })
        s.finish()
    }

    func testIsNoScreenViewOfItsOwnWhenItsPageAnsweredBeforeItsScreenWasShown() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/size-guide", coverage: 1)
        var attachment: WebAttachment?
        s.onCore { core in
            core.hub.begin(.push)
            attachment = core.attachWebView(webView)
        }
        // A page that loads fast says hello while its screen is still coming in, before the screen is read.
        receive(s, attachment!, hello)
        s.onCore { core in core.hub.shown("/size-guide", .push) }
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/"], screens(s))
        s.finish()
    }

    func testMeasuresAWebViewAgainOnceTheScreenItAnsweredOnIsShown() {
        let s = start()
        // A third of the window as its page answers, sliding in with its screen, and all of it once the screen is in.
        let webView = FakeWebView(url: "\(shop)/size-guide", coverage: 0.3)
        var attachment: WebAttachment?
        s.onCore { core in
            core.hub.begin(.push)
            attachment = core.attachWebView(webView)
        }
        receive(s, attachment!, hello)
        webView.coverage = 1
        s.onCore { core in core.hub.shown("/size-guide", .push) }
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/"], screens(s))
        s.finish()
    }

    func testKeepsItsScreenViewWhenThePartOfTheScreenItIsAnsweredBeforeTheScreenWasShown() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/banner", coverage: 0.2)
        var attachment: WebAttachment?
        s.onCore { core in
            core.hub.begin(.push)
            attachment = core.attachWebView(webView)
        }
        receive(s, attachment!, hello)
        s.onCore { core in core.hub.shown("/size-guide", .push) }
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/", "/size-guide"], screens(s))
        s.finish()
    }

    func testKeepsItsScreenViewWhenNoPageAnswers() {
        let s = start()
        let webView = FakeWebView(url: "https://elsewhere.example.org/", coverage: 1)
        let attachment = sizeGuide(s, webView)!
        receive(s, attachment, hello)
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/", "/size-guide"], screens(s))
        s.finish()
    }

    func testKeepsItsScreenViewWhereTheWebViewIsOnlyAPartOfTheScreen() {
        let s = start()
        let webView = FakeWebView(url: "\(shop)/banner", coverage: 0.2)
        let attachment = sizeGuide(s, webView)!
        receive(s, attachment, hello)
        s.advanceMillis(6_000)
        s.sendAll()

        XCTAssertEqual(["/", "/size-guide"], screens(s))
        XCTAssertEqual(1, webView.contexts.count)
        s.finish()
    }
}
