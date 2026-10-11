#if os(iOS)
    import WebKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore

    /// The cookie store every web view of the app shares, WebKit's own, in the simulator: what the SDK writes there is
    /// what a page on each website reads, and what a page writes is what the SDK reads back.
    final class WebCookieStoreTests: XCTestCase {
        private let shop = WebOrigin.parse("https://shop.example.com")!
        private let local = WebOrigin.parse("http://localhost:4173")!
        private let names = [WebViews.deviceCookie, WebViews.sessionCookie]

        override func setUp() {
            clear()
        }

        override func tearDown() {
            clear()
        }

        private func clear() {
            let done = expectation(description: "cleared")
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { all in
                let group = DispatchGroup()
                for c in all {
                    group.enter()
                    store.delete(c) { group.leave() }
                }
                group.notify(queue: .main) { done.fulfill() }
            }
            wait(for: [done], timeout: 10)
        }

        private func write(_ cookies: [WebCookie]) -> Bool {
            let done = expectation(description: "written")
            var ok = false
            WebCookieStore.write(cookies) {
                ok = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return ok
        }

        private func read(_ origins: [WebOrigin]) -> [[String: String]]? {
            let done = expectation(description: "read")
            var values: [[String: String]]?
            WebCookieStore.read(origins, names) {
                values = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return values
        }

        func testWhatIsWrittenIsWhatEachWebsitesPagesRead() {
            let session = WebSession("s-1", 1_791_191_702_000).value
            XCTAssertTrue(
                write([
                    WebCookie(shop, WebViews.deviceCookie, "d-1", WebViews.deviceMaxAgeSeconds),
                    WebCookie(shop, WebViews.sessionCookie, session, 1860),
                    WebCookie(local, WebViews.deviceCookie, "d-1", WebViews.deviceMaxAgeSeconds),
                ]))
            let values = read([shop, local, WebOrigin.parse("https://blog.example.com")!])
            XCTAssertEqual(
                values,
                [
                    [WebViews.deviceCookie: "d-1", WebViews.sessionCookie: session],
                    [WebViews.deviceCookie: "d-1"],
                    [:],
                ], "host-only, as the tag writes them")

            let stored = cookies().filter { $0.name == WebViews.deviceCookie && $0.domain == "shop.example.com" }
            XCTAssertEqual(stored.count, 1)
            XCTAssertTrue(stored[0].isSecure, "Secure on an https page")
            XCTAssertEqual(stored[0].path, "/")
            XCTAssertEqual(stored[0].sameSitePolicy, .sameSiteLax)
        }

        func testACookieDomainIsTheDomainsAndItsSubdomainsAndAMaxAgeOfZeroDeletes() {
            let shared = WebOrigin.parse("https://shop.example.com", cookieDomain: "example.com")!
            XCTAssertTrue(write([WebCookie(shared, WebViews.deviceCookie, "d-2", WebViews.deviceMaxAgeSeconds)]))
            let blog = WebOrigin.parse("https://blog.example.com")!
            XCTAssertEqual(read([shop, blog]), [[WebViews.deviceCookie: "d-2"], [WebViews.deviceCookie: "d-2"]])

            XCTAssertTrue(write([WebCookie(shared, WebViews.deviceCookie, "", 0)]))
            XCTAssertEqual(read([shop, blog]), [[:], [:]])
        }

        func testAHostsOwnCookieIsReadBeforeAParentDomainsAndASecureOneOnlyOverHttps() {
            let shared = WebOrigin.parse("https://shop.example.com", cookieDomain: ".example.com")!
            XCTAssertTrue(
                write([
                    WebCookie(shared, WebViews.sessionCookie, "parent.mgj6k3cw", 1860),
                    WebCookie(shop, WebViews.sessionCookie, "own.mgj6k3cw", 1860),
                ]))
            XCTAssertEqual(read([shop])?.first?[WebViews.sessionCookie], "own.mgj6k3cw")
            let plain = WebOrigin.parse("http://shop.example.com")!
            XCTAssertNil(read([plain])?.first?[WebViews.sessionCookie], "every cookie written for https is Secure")
        }

        private func cookies() -> [HTTPCookie] {
            let done = expectation(description: "all")
            var all: [HTTPCookie] = []
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                all = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return all
        }
    }

    /// What iOS says about the app and the device in the simulator.
    final class FactsTests: XCTestCase {
        func testTheSimulatorIsADevelopersAndNamesTheDeviceItSimulates() {
            XCTAssertTrue(Facts.simulator)
            XCTAssertEqual(Facts.buildMode(), "debug")
            XCTAssertNotNil(Facts.machine())
            XCTAssertNotNil(Facts.processStartMs())
            XCTAssertLessThanOrEqual(Facts.processStartMs()!, Int64(Date().timeIntervalSince1970 * 1000))
        }

        func testTheSDKsFilesAreKeptWhereNoBackupCopiesThem() throws {
            let base = try XCTUnwrap(Facts.storageDirectory())
            let dir = URL(fileURLWithPath: base).appendingPathComponent("kontala", isDirectory: true)
            let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }

        func testTheDevicesIdsAreHeldToTheirShapes() {
            let ids = Facts.deviceIds()
            XCTAssertNotNil(ids.adTracking)
            XCTAssertNil(ids.androidId)
            if let idfv = ids.idfv { XCTAssertEqual(idfv.count, 36) }
        }
    }
#endif
