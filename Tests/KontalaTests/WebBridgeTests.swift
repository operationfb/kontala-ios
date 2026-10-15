#if os(iOS)
    import UIKit
    import WebKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// The bridge between the app and a page it shows, in a real WKWebView: the page's own script finds
    /// `window.KontalaAppBridge`, says hello, and is told the app's context, which the Kontala tag on a page takes from
    /// `window.pageTrackerQueue`.
    final class WebBridgeTests: XCTestCase {
        private let shop = "https://shop.example.com"
        private var window: UIWindow!
        private var web: WKWebView!
        private var s: Session!

        override func setUp() {
            Kontala.debugReset()
            s = startKontala(KontalaOptions(webOrigins: [shop]), served: contract2(), cookies: FakeCookieStore())
            Kontala.screen("/")
            s.scheduler.runDue()
            window = UIWindow(frame: UIScreen.main.bounds)
            let vc = UIViewController()
            // A part of the screen, as a delivery note's is: the screen's own screen view stays.
            let bounds = vc.view.bounds
            web = WKWebView(
                frame: CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 4),
                configuration: WKWebViewConfiguration())
            vc.view.addSubview(web)
            window.rootViewController = vc
            window.makeKeyAndVisible()
        }

        override func tearDown() {
            window.isHidden = true
            Kontala.debugReset()
        }

        /// Runs the main thread and the core's queue in turn until [done] or [seconds] pass.
        private func pump(_ seconds: TimeInterval = 20, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                s.scheduler.runDue()
                if done() { return }
                spin()
            }
        }

        private func load(_ body: String, at path: String = "/size-guide") {
            web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: shop + path))
        }

        /// What the page's script evaluates [js] to, as text.
        private func page(_ js: String) -> String? {
            var out: String?
            var answered = false
            web.evaluateJavaScript(js) { value, _ in
                out = value as? String
                answered = true
            }
            pump(10) { answered }
            return out
        }

        /// The contexts the app told the page, from what it pushed onto the tag's queue.
        private func contexts() -> [JSONObject] {
            guard let text = page("JSON.stringify(window.pageTrackerQueue||[])"),
                let queue = (try? Json.decode(text))?.array
            else { return [] }
            return queue.compactMap { entry in
                guard let pair = entry.array, pair.count == 2, pair[0] == "app" else { return nil }
                return pair[1].object
            }
        }

        private let challenge = "5b8f2c1e-9d3a-4e7b-8c6f-1a2b3c4d5e6f"

        /// What a page with the tag on it says first: hello, with a challenge the app's answer echoes.
        private var hello: String { "JSON.stringify({kontala:1,type:'hello',challenge:'\(challenge)'})" }

        func testAPageOnOneOfTheWebsitesIsToldTheAppsContext() {
            Kontala.attachWebView(web)
            load("<script>window.pageTrackerQueue=[];window.KontalaAppBridge.postMessage(\(hello));</script>")
            var told: [JSONObject] = []
            pump {
                told = contexts()
                return !told.isEmpty
            }
            XCTAssertEqual(1, told.count)
            let context = told.first ?? JSONObject()
            XCTAssertEqual(1, context.long("v"))
            XCTAssertEqual(challenge, context.str("challenge"))
            XCTAssertGreaterThanOrEqual(context.str("nonce")?.count ?? 0, 16)
            XCTAssertEqual("granted", context.str("consent"))
            XCTAssertEqual("com.example.shop", context.obj("app")?.str("id"))
            XCTAssertEqual("kontala-ios", context.obj("app")?.str("sdk"))
            s.sendAll()
            let view = s.collector.named("page_view").first
            XCTAssertEqual(view?.str("device"), context.str("device"))
            XCTAssertEqual(view?.str("session"), context.str("session"))
        }

        /// The Kontala tag as the collector serves it to a key with no configuration, the lite bundle committed beside
        /// the collector, which every page carries.
        private static let tag: String = {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let url = root.appendingPathComponent("collector/internal/tagasset/page-tracker.lite.min.js")
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }()

        /// Loads a page with the Kontala tag on it, whose events are kept in `window.events` as it logs them, and
        /// then a script of the page's own, which pushes a context no app sent, as any script could.
        private func loadTheTag() {
            XCTAssertFalse(Self.tag.isEmpty, "the committed lite bundle")
            let keep =
                "<script>window.events=[];console.log=function(m){try{window.events.push(JSON.parse(m));}catch(e){}};"
                + "</script>"
            let forge =
                "<script>window.pageTrackerQueue.push(['app',{v:1,nonce:'forged-nonce-0123456789',"
                + "app:{id:'la.konta.forged'},device:'forged-device',session:'forged-session',last_seen:Date.now(),"
                + "consent:'denied'}]);</script>"
            load(keep + "<script>" + Self.tag + "</script>" + forge)
        }

        /// Starts Kontala again on the device's own clock, which the tag on a page reads, as an app's is: on the
        /// suite's fixed clock the page's visit would begin long after the app's, and be the one both keep.
        private func restartOnTheDevicesClock(_ options: KontalaOptions) {
            Kontala.debugReset()
            s = startKontala(
                options, served: contract2(), start: Int64(Date().timeIntervalSince1970 * 1_000_000),
                cookies: FakeCookieStore())
            Kontala.screen("/")
            s.scheduler.runDue()
        }

        /// The events the tag on the page has released, once at least one.
        private func released() -> [JSONObject] {
            var events: [JSONObject] = []
            pump {
                events =
                    page("JSON.stringify(window.events||[])").flatMap { (try? Json.decode($0))?.array }?
                    .compactMap { $0.object } ?? []
                return !events.isEmpty
            }
            return events
        }

        func testTheTagOnAPageTakesTheAppsAnswerAndNothingAScriptOfThePageSays() {
            restartOnTheDevicesClock(KontalaOptions(webOrigins: [shop]))
            Kontala.attachWebView(web)
            loadTheTag()
            let events = released()
            s.sendAll()
            let view = s.collector.named("page_view").first
            XCTAssertFalse(events.isEmpty)
            for e in events {
                XCTAssertEqual("com.example.shop", e.obj("app")?.str("id"))
                XCTAssertEqual(view?.str("device"), e.str("device"))
                XCTAssertEqual(view?.str("session"), e.str("session"))
                XCTAssertEqual("granted", e.str("consent"))
            }
            XCTAssertEqual("granted", page("window.pageTracker.getConsent()"))
        }

        func testTheTagOnAPageTakesAPinnedSessionFromTheApp() {
            restartOnTheDevicesClock(KontalaOptions(sessionId: "pinned-session", webOrigins: [shop]))
            Kontala.attachWebView(web)
            loadTheTag()
            let events = released()
            XCTAssertFalse(events.isEmpty)
            for e in events {
                XCTAssertEqual("pinned-session", e.str("session"))
                XCTAssertEqual("com.example.shop", e.obj("app")?.str("id"))
            }
        }

        func testAScreenTheWebViewFillsHasItsScreenViewWithdrawnOnceItsPageAnswers() {
            web.frame = window.bounds
            Kontala.screen("/size-guide")
            s.scheduler.runDue()
            Kontala.attachWebView(web)
            load("<script>window.pageTrackerQueue=[];window.KontalaAppBridge.postMessage(\(hello));</script>")
            pump { !contexts().isEmpty }
            s.advanceMillis(6000)
            s.sendAll()
            XCTAssertEqual(["/"], s.screens, "the page's own page views count the size guide")
        }

        func testAFrameInsideThePageFindsNoBridgeAndIsAnsweredNothing() {
            Kontala.attachWebView(web)
            // The frame reaches the app's handler itself, as WebKit lets any frame: the handler drops it.
            let frame =
                "<script>parent.frameSaw='ran:'+typeof window.KontalaAppBridge;"
                + "window.webkit.messageHandlers.\(WebViews.bridgeChannel).postMessage(\(hello));"
                + "parent.framePosted='posted';</script>"
            load(
                "<script>window.pageTrackerQueue=[];</script>"
                    + "<iframe srcdoc=\"\(frame.replacingOccurrences(of: "\"", with: "&quot;"))\"></iframe>")
            pump { page("String(window.framePosted)") == "posted" }
            XCTAssertEqual("ran:undefined", page("String(window.frameSaw)"))
            XCTAssertEqual("posted", page("String(window.framePosted)"))
            pump(3) { false }
            XCTAssertEqual([], contexts())
            // The page's own hello is answered, so the frame's was dropped rather than not yet answered.
            _ = page("window.KontalaAppBridge.postMessage(\(hello)),'sent'")
            var told: [JSONObject] = []
            pump {
                told = contexts()
                return !told.isEmpty
            }
            XCTAssertEqual(1, told.count)
        }

        func testADetachedWebViewsNextPageFindsNoBridge() {
            let attachment = Kontala.attachWebView(web)
            let saw = "<script>window.saw='ran:'+typeof window.KontalaAppBridge;</script>"
            load(saw)
            pump { page("String(window.saw)") == "ran:object" }
            XCTAssertEqual("ran:object", page("String(window.saw)"))
            attachment.detach()
            pump(1) { false }
            load(saw, at: "/returns")
            pump { page("String(window.saw)") == "ran:undefined" }
            XCTAssertEqual("ran:undefined", page("String(window.saw)"))
        }

        func testAWebViewCoversTheShareOfItsWindowItShows() {
            let half = UIView(
                frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height / 2))
            window.rootViewController?.view.addSubview(half)
            XCTAssertEqual(0.25, WebBridge.coverage(web), accuracy: 0.01)
            web.frame = window.bounds
            XCTAssertEqual(1, WebBridge.coverage(web), accuracy: 0.01)
            XCTAssertEqual(0.5, WebBridge.coverage(half), accuracy: 0.01)
            half.isHidden = true
            XCTAssertEqual(0, WebBridge.coverage(half))
            XCTAssertEqual(0, WebBridge.coverage(UIView()), "in no window")
        }

        func testBeforeTheSDKStartsTheAttachmentDoesNothing() {
            Kontala.debugReset()
            let attachment = Kontala.attachWebView(web)
            XCTAssertTrue(attachment is InertAttachment)
            XCTAssertTrue(web.configuration.userContentController.userScripts.isEmpty)
        }
    }
#endif
