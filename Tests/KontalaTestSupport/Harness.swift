import Foundation
import KontalaCore

// What the suites run the SDK on, faked: a virtual clock, a collector, a
// platform, a cookie store and a web view. A target of its own, which both the
// core's suite and the UIKit half's read, so a pipeline from a view controller
// to the collector runs on the same fakes as the core's sessions.

/// Where the repository is: `KONTALA_REPO`, else four levels above this file's folder.
package let repo: URL = {
    if let r = ProcessInfo.processInfo.environment["KONTALA_REPO"] { return URL(fileURLWithPath: r) }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KontalaTestSupport
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // sdk
        .deletingLastPathComponent()
}()

/// A JSON file of the repository's, read as the SDK reads JSON.
package func repoJson(_ path: String) -> JSONObject {
    let data = try! Data(contentsOf: repo.appendingPathComponent(path))
    guard let o = Json.decodeObject(data) else { fatalError("\(path) is not a JSON object") }
    return o
}

/// Whether the goldens are being rewritten (`KONTALA_UPDATE_GOLDENS=1 swift test`).
package let updateGoldens = ProcessInfo.processInfo.environment["KONTALA_UPDATE_GOLDENS"] == "1"

/// The API tests' own `testNow`, which the Flutter SDK's goldens start at too: 2026-10-05T09:15:02Z.
package let goldenStartMicros: Int64 = 1_791_191_702_000_000

/// One queue's worth of time, faked: tasks posted run in order when the test runs what is due, and a timer runs at
/// its own moment as the test moves time on, as Flutter's fake async does.
package final class FakeScheduler: Scheduler {
    private final class Task {
        let at: Int64
        let seq: Int64
        let f: () -> Void
        var cancelled = false

        init(at: Int64, seq: Int64, f: @escaping () -> Void) {
            self.at = at
            self.seq = seq
            self.f = f
        }
    }

    package var nowMicros: Int64
    private var tasks: [Task] = []
    private var seq: Int64 = 0

    package init(nowMicros: Int64 = goldenStartMicros) {
        self.nowMicros = nowMicros
    }

    package let onThread = true

    private func insert(_ t: Task) {
        let i = tasks.firstIndex { ($0.at, $0.seq) > (t.at, t.seq) } ?? tasks.count
        tasks.insert(t, at: i)
    }

    package func post(_ task: @escaping () -> Void) {
        insert(Task(at: nowMicros, seq: seq, f: task))
        seq += 1
    }

    package func schedule(_ delayMicros: Int64, _ task: @escaping () -> Void) -> Cancellable {
        let t = Task(at: nowMicros + max(0, delayMicros), seq: seq, f: task)
        seq += 1
        insert(t)
        return Cancellable { t.cancelled = true }
    }

    /// Runs everything due now, and whatever that posts.
    package func runDue() {
        while let t = tasks.first, t.at <= nowMicros {
            tasks.removeFirst()
            if !t.cancelled { t.f() }
        }
    }

    /// Moves time on by [micros], running every timer at its own moment.
    package func advance(_ micros: Int64) {
        let end = nowMicros + micros
        runDue()
        while let t = tasks.first, t.at <= end {
            if t.at > nowMicros { nowMicros = t.at }
            runDue()
        }
        nowMicros = end
        runDue()
    }

    package func advanceMillis(_ ms: Int64) { advance(ms * 1000) }

    /// How many timers are still pending, cancelled ones aside.
    package var pendingTimers: Int { tasks.filter { !$0.cancelled }.count }
}

/// A collector that answers every request as the Events API answers a valid one, and keeps what it was sent.
package final class FakeCollector: Http {
    package var requests: [JSONObject] = []
    package var headers: [[String: String]] = []

    /// What the next requests are answered with, by default a 200 accepting every event.
    package var answer: ((JSONObject) -> HttpAnswer)?

    /// What `GET /v1/events/config` serves: by default nothing, a 404, so the app writes contract 1.
    package var served: JSONObject?

    /// The status every read of the configuration is answered with instead, with no body.
    package var configStatus: Int?

    package var configHeaders: [[String: String]] = []

    /// Whether a request is answered at once (the default) or kept for `release`.
    package var hold = false
    private var held: [() -> Void] = []

    package init() {}

    package var events: [JSONObject] { requests.flatMap { ($0.list("events") ?? []).compactMap { $0.object } } }

    /// The events named [name], in the order they were sent.
    package func named(_ name: String) -> [JSONObject] { events.filter { $0.str("event") == name } }

    package func post(
        _ url: String, _ headers: [String: String], _ body: Data, _ done: @escaping (HttpAnswer?, Error?) -> Void
    ) {
        let bytes = headers["Content-Encoding"] == "gzip" ? gunzip(body)! : body
        let json = Json.decodeObject(bytes)!
        requests.append(json)
        self.headers.append(headers)
        let a =
            answer?(json)
            ?? HttpAnswer(
                200,
                Data(
                    Json.encode(
                        [
                            "request_id": "req", "accepted": .int(Int64(json.list("events")!.count)), "rejected": [],
                            "warnings": [],
                        ] as JSONObject
                    ).utf8))
        if hold { held.append { done(a, nil) } } else { done(a, nil) }
    }

    package func release() {
        let h = held
        held.removeAll()
        for f in h { f() }
    }

    package func get(_ url: String, _ headers: [String: String], _ done: @escaping (HttpAnswer?, Error?) -> Void) {
        configHeaders.append(headers)
        if let s = configStatus {
            done(HttpAnswer(s), nil)
            return
        }
        guard let s = served else {
            done(HttpAnswer(404, Data("404 page not found\n".utf8)), nil)
            return
        }
        if let rev = s.str("rev"), headers["If-None-Match"] == "\"\(rev)\"" {
            done(HttpAnswer(304), nil)
            return
        }
        done(HttpAnswer(200, Data(Json.encode(s).utf8)), nil)
    }
}

/// What the platform answers in a test: an iPhone 15 Pro on iOS 18.1 in Amsterdam, as the Flutter SDK's harness
/// answers for iOS.
package func testFacts(storageDir: String? = nil, virtual: Bool = false) -> PlatformFacts {
    PlatformFacts(
        appId: "com.example.shop",
        appVersion: "3.2.0",
        appBuild: "412",
        osName: "ios",
        osVersion: "18.1",
        manufacturer: "Apple",
        model: "iPhone16,1",
        timezone: "Europe/Amsterdam",
        storageDir: storageDir,
        isTablet: false,
        isVirtual: virtual,
        buildMode: "debug"
    )
}

package final class FakePlatform: Platform {
    package var answeredFacts: PlatformFacts
    package var state: AppState
    package var ids: DeviceIds?
    package var lines: [String] = []

    /// The cookie store the app's web views share, where a test gives the platform one.
    package var cookies: FakeCookieStore?

    /// Whether a web view is on show, as the platform would find one in the screen in front.
    package var webViewOnShow = false

    /// What the app shows, as the platform's fingerprint reads it, where a test gives one; none reads as nil.
    package var fingerprinter: (() -> Int64?)?

    /// Told each time the app says its screen is fully displayed.
    package var readied: () -> Void = {}

    /// The background tasks begun and ended, by their tokens.
    package var tasksBegun = 0
    package var tasksEnded: [Int] = []

    package init(facts: PlatformFacts = testFacts(), state: AppState = .resumed, ids: DeviceIds? = nil) {
        answeredFacts = facts
        self.state = state
        self.ids = ids
    }

    package func facts() -> PlatformFacts { answeredFacts }
    package func initialState() -> AppState { state }
    package func localeTag() -> String? { "en-US" }
    package func displaySize() -> (Int, Int)? { (800, 600) }
    package func deviceIds(_ done: @escaping (DeviceIds?) -> Void) { done(ids) }
    package func requestTrackingAuthorization(_ done: @escaping (String?) -> Void) { done(ids?.adTracking) }
    package func log(_ line: String) { lines.append(line) }
    package let debuggable = false

    package func beginBackgroundTask() -> Any? {
        tasksBegun += 1
        return tasksBegun
    }

    package func endBackgroundTask(_ token: Any?) {
        if let t = token as? Int { tasksEnded.append(t) }
    }

    package func writeWebCookies(_ cookies: [WebCookie], _ done: @escaping (Bool) -> Void) {
        guard let store = self.cookies else { return done(false) }
        store.write(cookies)
        done(true)
    }

    package func readWebCookies(
        _ origins: [WebOrigin], _ names: [String], _ done: @escaping ([[String: String]]?) -> Void
    ) {
        guard let store = cookies else { return done(nil) }
        done(origins.map { o in (store.byUrl[o.url] ?? [:]).filter { names.contains($0.key) } })
    }

    package func webViewShown(_ frames: Int, _ done: @escaping (Bool) -> Void) { done(webViewOnShow) }

    package func fingerprint(_ done: @escaping (Int64?) -> Void) { done(fingerprinter?()) }

    package func screenReady() { readied() }
}

/// The cookie store the app's web views share: the cookies each origin's pages see.
package final class FakeCookieStore {
    /// The cookies each origin's pages see, by name.
    package var byUrl: [String: [String: String]] = [:]

    /// Every cookie written, as the platform was handed it.
    package var writes: [WebCookie] = []

    package init() {}

    package func write(_ cookies: [WebCookie]) {
        for c in cookies {
            writes.append(c)
            var page = byUrl[c.url] ?? [:]
            if c.maxAgeSeconds == 0 { page.removeValue(forKey: c.name) } else { page[c.name] = c.value }
            byUrl[c.url] = page
        }
    }

    /// The session a page on [url] reads.
    package func session(_ url: String) -> WebSession? { WebSession.parse(byUrl[url]?[WebViews.sessionCookie]) }
}

/// A web view as `Kontala.attachWebView` hands it to the core: the URL it shows and the scripts the app ran in it.
package final class FakeWebView: WebViewHost {
    package var url: String?
    package var coverage: Double
    package var scripts: [String] = []

    package init(url: String?, coverage: Double = 0) {
        self.url = url
        self.coverage = coverage
    }

    package func inspect(_ done: @escaping (String?, Double) -> Void) { done(url, coverage) }

    package func runJavaScript(_ source: String) { scripts.append(source) }

    /// The contexts the app told the page, read out of its scripts.
    package var contexts: [JSONObject] { scripts.map(contextOf) }
}

/// The context a script of the app's tells a page, read out of it.
package func contextOf(_ script: String) -> JSONObject {
    let open = script.range(of: "push([\"app\",")!
    let close = script.range(of: "]);})();", options: .backwards)!
    return Json.decodeObject(String(script[open.upperBound..<close.lowerBound]))!
}

/// A started SDK and everything it runs on, faked.
package final class Session {
    package let scheduler: FakeScheduler
    package let collector: FakeCollector
    package let platform: FakePlatform
    package let running: Kontala.Running

    package init(scheduler: FakeScheduler, collector: FakeCollector, platform: FakePlatform, running: Kontala.Running) {
        self.scheduler = scheduler
        self.collector = collector
        self.platform = platform
        self.running = running
    }

    package var core: Core { running.core }

    /// A lifecycle state as the platform reports it.
    package func lifecycle(_ state: AppState) {
        running.post { $0.lifecycleChanged(state) }
        scheduler.runDue()
    }

    /// The launch's first frame.
    package func firstFrame() {
        running.post { $0.firstFrame() }
        scheduler.runDue()
    }

    /// Runs [f] on the core, as the platform's signals do.
    package func onCore(_ f: @escaping (Core) -> Void) {
        running.post(f)
        scheduler.runDue()
    }

    package func advanceMillis(_ ms: Int64) { scheduler.advanceMillis(ms) }

    /// Sends everything captured so far, and lets the fake collector answer.
    package func sendAll() {
        Kontala.flush()
        for _ in 0..<5 { scheduler.advanceMillis(10) }
    }

    /// Stops the SDK.
    package func finish() {
        Kontala.debugReset()
        scheduler.runDue()
    }

    /// The screens' names, in the order their screen views were sent.
    package var screens: [String] { collector.named("page_view").map { $0.obj("screen")!.str("name")! } }
}

/// Starts Kontala as an app would, against a `FakeCollector`, on a fake clock. Calls made to `Kontala` before it are
/// kept, as an app's are; a suite resets the facade between tests with `Kontala.debugReset()`.
package func startKontala(
    _ options: KontalaOptions = KontalaOptions(),
    facts: PlatformFacts = testFacts(),
    served: JSONObject? = nil,
    ids: DeviceIds? = nil,
    state: AppState = .resumed,
    start: Int64 = goldenStartMicros,
    cookies: FakeCookieStore? = nil
) -> Session {
    let scheduler = FakeScheduler(nowMicros: start)
    let collector = FakeCollector()
    collector.served = served
    let platform = FakePlatform(facts: facts, state: state, ids: ids)
    platform.cookies = cookies
    guard
        let running = Kontala.start(
            writeKey: "pk_live_test",
            endpoint: "https://collector.test/v1/events",
            options: options,
            platform: platform,
            scheduler: scheduler,
            http: collector,
            clock: Clock(wallMicros: { scheduler.nowMicros }, monotonicNanos: { scheduler.nowMicros * 1000 }),
            main: { $0() },
            onStop: {}
        )
    else { fatalError("Kontala was started already") }
    scheduler.runDue()
    return Session(scheduler: scheduler, collector: collector, platform: platform, running: running)
}

/// What a region on contract 2 serves an app at `GET /v1/events/config`: the scroll and friction sections are the
/// ones the collector serves a tag, read from its own goldens, as the Flutter SDK's harness reads them.
package func contract2(
    rev: String = "rev-2", clicks: Bool = true, scroll: Bool = true, friction: Bool = true,
    customEvents: Bool = true, screenProperties: Bool = true
) -> JSONObject {
    var o: JSONObject = ["v": 1, "rev": .string(rev), "contract": 2]
    if clicks { o["clicks"] = ["v": 1] }
    if scroll { o["scroll"] = repoJson("collector/tagconfig/testdata/scroll.golden.json")["scroll"] }
    if friction { o["friction"] = repoJson("collector/tagconfig/testdata/friction.golden.json")["friction"] }
    o["custom_events"] = .bool(customEvents)
    o["screen_properties"] = .bool(screenProperties)
    return o
}

/// A temporary directory of its own, which the test's tear-down deletes.
package func temporaryDirectory() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kontala-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}
