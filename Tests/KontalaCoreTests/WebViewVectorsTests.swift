import Foundation
import XCTest

@testable import KontalaCore

/// What the app and a web page it shows agree on, collector/webview's vectors, which the tag, the other SDKs and the
/// collector are held to as well; and the bounds a view_time is sent within, collector/engagement's.
final class WebViewVectorsTests: XCTestCase {
    private let v = repoJson("collector/webview/testdata/vectors.json")

    private func cases(_ key: String) -> [JSONObject] { (v.list(key) ?? []).map { $0.object! } }

    private func session(_ raw: JSON?) -> WebSession? {
        guard let m = raw?.object else { return nil }
        return WebSession(m.str("id")!, m.long("last_seen")!)
    }

    func testAViewTimeIsSentWithTheTriggersAndWithinTheBoundTheCollectorKeeps() {
        let e = repoJson("collector/engagement/testdata/vectors.json")
        XCTAssertEqual(e.list("triggers")?.map { $0.string! }, EngagementPlugin.triggers)
        XCTAssertEqual(e.long("max_visible_ms"), EngagementPlugin.maxVisibleMs)
    }

    func testTheBridgeAndTheCookiesAreNamedAsTheTagNamesThem() {
        let bridge = v.obj("bridge")!
        let cookies = v.obj("cookies")!
        XCTAssertEqual(bridge.str("channel"), WebViews.bridgeChannel)
        XCTAssertEqual(bridge.long("version"), Int64(WebViews.bridgeVersion))
        XCTAssertEqual(cookies.str("device"), WebViews.deviceCookie)
        XCTAssertEqual(cookies.str("session"), WebViews.sessionCookie)
        XCTAssertEqual(cookies.long("device_max_age_s"), WebViews.deviceMaxAgeSeconds)
        XCTAssertEqual(cookies.long("session_extra_s"), WebViews.sessionExtraSeconds)
        XCTAssertEqual(cookies.long("write_interval_s"), WebViews.writeIntervalMillis / 1000)
    }

    func testACookieIsWrittenByteForByteAsTheTagWritesIt() {
        for c in cases("cookie_strings") {
            let origin = WebOrigin.parse(c.str("origin")!, cookieDomain: c.str("domain"))!
            XCTAssertEqual(
                c.str("string"), cookieHeader(c.str("name")!, c.str("value")!, c.long("max_age_s")!, origin),
                "\(c.str("name")!) on \(c.str("origin")!)")
        }
    }

    func testASessionRecordReadsAsTheTagReadsIt() {
        for c in cases("session_records") {
            XCTAssertEqual(session(c["session"]), WebSession.parse(c.str("raw")), c.str("raw")!)
        }
        let s = WebSession("0d7e6f5a-4b3c-4d2e-9f10-a1b2c3d4e5f6", 1_760_000_000_000)
        XCTAssertEqual(s, WebSession.parse(s.value))
    }

    func testBothKeepTheSessionTheRuleKeeps() {
        for c in cases("merge") {
            XCTAssertEqual(
                session(c["kept"]), mergeSessions(session(c["app"]), session(c["page"]), c.long("timeout_ms")!),
                c.str("case")!)
        }
    }

    func testTheAppTakesAPagesSessionAsTheRuleKeepsIt() {
        for c in cases("merge") {
            guard let app = session(c["app"]), let page = session(c["page"]), let kept = session(c["kept"]) else {
                continue
            }
            let identity = Identity(store: FileStore(baseDir: nil), timeoutMillis: c.long("timeout_ms")!)
            identity.mergeWeb(app.id, app.lastSeen)
            identity.mergeWeb(page.id, page.lastSeen)
            XCTAssertEqual(kept, identity.sessionNow(), c.str("case")!)
        }
    }

    func testAPinnedSessionIsTheAppsOwnWordAndStands() {
        let identity = Identity(store: FileStore(baseDir: nil), timeoutMillis: 60_000, pinnedSession: "pinned")
        XCTAssertFalse(identity.mergeWeb("page", 1_760_000_000_000))
        XCTAssertEqual("pinned", identity.sessionNow()?.id)
    }

    func testAPagesMessageIsReadAsTheVectorsReadItWithTheNonceTheAppGaveIt() {
        for c in cases("messages") {
            let m = PageMessage.read(c.str("sent")!, nonce: c.str("nonce")!)
            let reason = c.str("case")!
            guard let read = c.obj("read") else {
                XCTAssertNil(m, reason)
                continue
            }
            switch read.str("type") {
            case "hello":
                XCTAssertEqual(.hello, m, reason)
            case "activity":
                guard case .activity(let s)? = m else { return XCTFail(reason) }
                XCTAssertEqual(session(read["session"]), s, reason)
            case "identify":
                guard case .identify(let user, let org)? = m else { return XCTFail(reason) }
                XCTAssertEqual(read.str("user"), user, reason)
                XCTAssertEqual(read.str("org"), org, reason)
            default:
                XCTFail("an unknown message type: \(reason)")
            }
        }
    }

    func testACookieDomainFitsAPageAsTheTagDecides() {
        for c in cases("cookie_domains") {
            XCTAssertEqual(
                c["fits"]?.bool, WebOrigin.domainFits(c.str("domain")!, c.str("host")!),
                "\(c.str("domain")!) on \(c.str("host")!)")
        }
    }

    func testAConfigurationNamesAtMostTheWebsitesTheCollectorServes() {
        let origins: [JSON] = (1...120).map { ["origin": .string("https://site-\($0).example.com")] }
        let c = ServedConfig.parse(["v": 1, "contract": 2, "web_views": ["origins": .array(origins)]])!
        XCTAssertEqual(ServedConfig.maxWebOrigins, c.webOrigins.count)
        XCTAssertEqual("https://site-1.example.com", c.webOrigins.first?.value)
    }

    func testTheStoresCookiesAreReadAsAPagesScriptReadsThem() {
        let names = [WebViews.deviceCookie, WebViews.sessionCookie]
        let shop = WebOrigin.parse("https://shop.example.com")!
        let cookies = [
            StoredCookie(name: "other", value: "1", domain: "shop.example.com"),
            StoredCookie(name: "pt_sid", value: "parent.mgj6k3cw", domain: ".example.com"),
            StoredCookie(name: "pt_sid", value: "s.mgj6k3cw", domain: "shop.example.com", secure: true),
            StoredCookie(name: "pt_did", value: "d", domain: "shop.example.com"),
            StoredCookie(name: "pt_did", value: "deep", domain: "shop.example.com", path: "/checkout"),
            StoredCookie(name: "pt_did", value: "elsewhere", domain: "blog.example.com"),
        ]
        XCTAssertEqual(["pt_sid": "s.mgj6k3cw", "pt_did": "d"], WebCookies.pick(cookies, for: shop, names))
        // A Secure cookie is no page's on http.
        let plain = WebOrigin.parse("http://shop.example.com")!
        XCTAssertEqual(["pt_sid": "parent.mgj6k3cw", "pt_did": "d"], WebCookies.pick(cookies, for: plain, names))
        XCTAssertEqual([:], WebCookies.pick([], for: shop, names))
        XCTAssertEqual(
            ".example.com", WebCookies.domain(for: WebOrigin.parse(shop.value, cookieDomain: "example.com")!))
        XCTAssertEqual("shop.example.com", WebCookies.domain(for: shop))
    }

    func testTheStampsTheTagKeepsComeFromWhatTheAppSays() {
        // What the app tells a page, as the tag reads its app's fields (APP_TEXT in tag/core/core.app.ts).
        let appText = Pattern("^[\\w .()+@/-]{1,64}$")
        for value in [sdkLibraryName, sdkVersion, "debug", "release"] { XCTAssertTrue(appText.matches(value), value) }
    }
}
