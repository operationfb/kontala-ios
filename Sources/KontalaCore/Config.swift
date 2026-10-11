import Foundation

/// The contract of the Events API this SDK writes at most: 2 adds what an app measures of a screen, its device and its
/// forms.
package let sdkContract = 2

/// What makes a swipe, and how many one page sends: the served scroll section's, held to the bounds the tag holds it
/// to.
package struct SwipeRules: Equatable {
    package var perView: Int
    package var perPage: Int
    package var minPx: Int
    package var maxMs: Int
    package var axisRatio: Double
    package var edgePx: Int
}

/// The served scroll section: when a view's first depth reading is taken, and what makes a swipe.
package struct ScrollRules: Equatable {
    package var settleMs: Int
    package var maxWaitMs: Int
    package var swipes: SwipeRules

    /// The section as the collector serves it (collector/scroll.Serve), or nil for one this SDK does not read, which
    /// binds nothing: a threshold falling back to a floor would turn every wiggle into a swipe.
    package static func parse(_ raw: JSON?) -> ScrollRules? {
        guard let r = raw?.object, isOne(r["v"]), let depth = r.obj("depth"), let swipes = r.obj("swipes") else {
            return nil
        }
        let v = [
            bounded(depth["settle_ms"], 250, 10000),
            bounded(depth["max_wait_ms"], 250, 30000),
            bounded(swipes["per_view"], 0, 500),
            bounded(swipes["per_page"], 0, 5000),
            bounded(swipes["min_px"], 10, 1000),
            bounded(swipes["max_ms"], 100, 10000),
            bounded(swipes["axis_ratio"], 1, 10, whole: false),
            bounded(swipes["edge_px"], 0, 200),
        ]
        if v.contains(where: { $0 == nil }) { return nil }
        let d = v.map { $0! }
        return ScrollRules(
            settleMs: Int(d[0]),
            maxWaitMs: Int(d[1]),
            swipes: SwipeRules(
                perView: Int(d[2]), perPage: Int(d[3]), minPx: Int(d[4]), maxMs: Int(d[5]), axisRatio: d[6],
                edgePx: Int(d[7]))
        )
    }
}

/// The served friction section: the caps and waits of its five rows, held to the bounds the tag holds them to.
package struct FrictionRules: Equatable {
    package var errorsPerView: Int
    package var errorsPerPage: Int
    package var errorClickMs: Int
    package var rageClicks: Int
    package var rageWindowMs: Int
    package var rageRadiusPx: Int
    package var ragePerView: Int
    package var ragePerPage: Int
    package var deadWaitMs: Int
    package var deadLateMs: Int
    package var deadPerView: Int
    package var deadPerPage: Int
    package var speedSettleMs: Int
    package var speedMaxWaitMs: Int
    package var speedRowsPerView: Int
    package var restoresPerPage: Int

    /// The section as the collector serves it (collector/friction.Serve), or nil for one this SDK does not read.
    package static func parse(_ raw: JSON?) -> FrictionRules? {
        guard let r = raw?.object, isOne(r["v"]), let errors = r.obj("errors"), let rage = r.obj("rage"),
            let dead = r.obj("dead"), let speed = r.obj("speed"), let restores = r.obj("restores")
        else { return nil }
        let v = [
            bounded(errors["per_view"], 0, 100),
            bounded(errors["per_page"], 0, 1000),
            bounded(errors["click_ms"], 0, 10000),
            bounded(rage["clicks"], 2, 10),
            bounded(rage["window_ms"], 100, 5000),
            bounded(rage["radius_px"], 1, 500),
            bounded(rage["per_view"], 0, 100),
            bounded(rage["per_page"], 0, 1000),
            bounded(dead["wait_ms"], 100, 10000),
            bounded(dead["late_ms"], 1000, 60000),
            bounded(dead["per_view"], 0, 100),
            bounded(dead["per_page"], 0, 1000),
            bounded(speed["settle_ms"], 250, 10000),
            bounded(speed["max_wait_ms"], 250, 30000),
            bounded(speed["rows_per_view"], 1, 100),
            bounded(restores["per_page"], 0, 1000),
        ]
        if v.contains(where: { $0 == nil }) { return nil }
        let i = v.map { Int($0!) }
        return FrictionRules(
            errorsPerView: i[0],
            errorsPerPage: i[1],
            errorClickMs: i[2],
            rageClicks: i[3],
            rageWindowMs: i[4],
            rageRadiusPx: i[5],
            ragePerView: i[6],
            ragePerPage: i[7],
            deadWaitMs: i[8],
            // A late answer is watched for past the wait, never before it.
            deadLateMs: i[9] > i[8] ? i[9] : i[8],
            deadPerView: i[10],
            deadPerPage: i[11],
            speedSettleMs: i[12],
            speedMaxWaitMs: i[13],
            speedRowsPerView: i[14],
            restoresPerPage: i[15]
        )
    }
}

/// Whether a JSON value is the number 1, as Dart's `raw['v'] != 1` reads it.
private func isOne(_ v: JSON?) -> Bool {
    switch v {
    case .int(let i)?: return i == 1
    case .double(let d)?: return d == 1
    default: return false
    }
}

/// A number held to [min, max], whole unless said otherwise, or nil for one that is not a finite number.
private func bounded(_ value: JSON?, _ min: Double, _ max: Double, whole: Bool = true) -> Double? {
    guard let d = value?.number, d.isFinite else { return nil }
    // Dart's round() is half away from zero.
    let v = whole ? roundHalfAway(d) : d
    return v < min ? min : (v > max ? max : v)
}

package func roundHalfAway(_ d: Double) -> Double {
    d < 0 ? -(-d + 0.5).rounded(.down) : (d + 0.5).rounded(.down)
}

/// What the region's collector serves this app at `GET /v1/events/config`: which contract it reads, and what the
/// property captures.
///
/// Contract 1 is what a collector that answers 404 reads, and what an app assumes until a collector says otherwise.
package struct ServedConfig: Equatable {
    package var contract: Int
    package var rev: String?
    /// Whether the property captures clicks and taps.
    package var clicks: Bool
    /// Scroll depth and swipes, when the property captures them at contract 2.
    package var scroll: ScrollRules?
    /// Friction and speed, when the property captures them at contract 2.
    package var friction: FrictionRules?
    /// Whether the property keeps the Events API's custom events, the lifecycle's among them.
    package var customEvents: Bool
    /// Whether the property keeps a screen view's properties.
    package var screenProperties: Bool
    /// The websites the app shows in a web view, with which the SDK shares its visitor and its visit: the property's
    /// own allowed origins and the other websites of the organisation it names in Kontala.
    package var webOrigins: [WebOrigin]

    package init(
        contract: Int, rev: String? = nil, clicks: Bool = true, scroll: ScrollRules? = nil,
        friction: FrictionRules? = nil, customEvents: Bool = true, screenProperties: Bool = true,
        webOrigins: [WebOrigin] = []
    ) {
        self.contract = contract
        self.rev = rev
        self.clicks = clicks
        self.scroll = scroll
        self.friction = friction
        self.customEvents = customEvents
        self.screenProperties = screenProperties
        self.webOrigins = webOrigins
    }

    /// What an app sends to a collector that has said nothing.
    package static let contract1 = ServedConfig(contract: 1)

    /// The most origins one configuration names, the collector's own bound.
    package static let maxWebOrigins = 100

    /// The `web_views` section's origins, each once, what of it is not one left out.
    private static func webOrigins(_ raw: JSON?) -> [WebOrigin] {
        guard let list = raw?.object?.list("origins") else { return [] }
        var out: [WebOrigin] = []
        for o in list {
            if out.count == maxWebOrigins { break }
            guard let m = o.object, let origin = m.str("origin"),
                let w = WebOrigin.parse(origin, cookieDomain: m.str("cookie_domain"))
            else { continue }
            if !out.contains(where: { $0.value == w.value }) { out.append(w) }
        }
        return out
    }

    /// The served document, read; nil for one that is not a configuration, or says a contract this SDK cannot write,
    /// which is then read as the highest it can.
    package static func parse(_ raw: JSON?) -> ServedConfig? {
        guard let r = raw?.object, isOne(r["v"]), let n = r.long("contract"), n >= 1 else { return nil }
        let rev = r.str("rev")
        let c = n > Int64(sdkContract) ? sdkContract : Int(n)
        return ServedConfig(
            contract: c,
            rev: rev.flatMap { !$0.isEmpty && $0.utf16.count <= 64 ? $0 : nil },
            clicks: r.obj("clicks") != nil,
            scroll: c >= 2 ? ScrollRules.parse(r["scroll"]) : nil,
            friction: c >= 2 ? FrictionRules.parse(r["friction"]) : nil,
            customEvents: r["custom_events"] == .bool(true),
            screenProperties: r["screen_properties"] == .bool(true),
            webOrigins: webOrigins(r["web_views"])
        )
    }
}

/// Reads the configuration the region's collector serves this app, keeps it for the next launch while storage is
/// allowed, and reads it again as the app launches and as it comes back after `maxAgeMicros`.
///
/// | Answer                  | Done                                                              |
/// |-------------------------|-------------------------------------------------------------------|
/// | 200                     | Read and kept.                                                    |
/// | 304                     | The kept one stands.                                              |
/// | 404, 405                | Contract 1: a collector that predates it.                         |
/// | 401                     | Sending stops for the process, as a refused key stops it on POST. |
/// | 503, another, no answer | The kept one stands, contract 1 with none.                        |
///
/// Only the core's queue calls it; the request's answer is posted back there.
package final class ConfigClient {
    package static let file = "config.json"
    package static let maxAgeMicros: Int64 = 5 * 60 * 1_000_000

    private let endpoint: String
    private let writeKey: String
    private let store: FileStore
    private let clock: Clock
    private let libraryVersion: String
    private let http: Http
    private let scheduler: Scheduler
    /// Told each time what is served changes.
    private let onChange: ((ServedConfig) -> Void)?
    /// Told when the key is refused.
    private let onHalt: (() -> Void)?
    private let log: ((String) -> Void)?

    package private(set) var current = ServedConfig.contract1

    private var raw: JSONObject?
    private var fetchedAtMicros: Int64?
    private var inFlight = false
    private var closed = false
    private var waiting: [() -> Void] = []

    package init(
        endpoint: String, writeKey: String, store: FileStore, clock: Clock, libraryVersion: String, http: Http,
        scheduler: Scheduler, onChange: ((ServedConfig) -> Void)? = nil, onHalt: (() -> Void)? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.writeKey = writeKey
        self.store = store
        self.clock = clock
        self.libraryVersion = libraryVersion
        self.http = http
        self.scheduler = scheduler
        self.onChange = onChange
        self.onHalt = onHalt
        self.log = log
    }

    /// The Events API's endpoint with `/config` after its path, and no query.
    package var url: String { ConfigClient.configURL(endpoint) }

    /// [endpoint] with `/config` after its path, its query and fragment left out.
    package static func configURL(_ endpoint: String) -> String {
        guard let sep = endpoint.range(of: "://") else { return endpoint + "/config" }
        let rest = endpoint[sep.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let afterAuthority = rest[authorityEnd...]
        let pathEnd = afterAuthority.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? afterAuthority.endIndex
        var path = String(afterAuthority[..<pathEnd])
        while path.hasSuffix("/") { path.removeLast() }
        return String(endpoint[..<sep.upperBound]) + String(rest[..<authorityEnd]) + path + "/config"
    }

    /// Whether the configuration is older than `maxAgeMicros`, or was never read.
    package var stale: Bool {
        guard let at = fetchedAtMicros else { return true }
        return clock.nowMicros() - at > ConfigClient.maxAgeMicros
    }

    /// Reads what an earlier launch kept, so the launch captures by it at once.
    package func loadKept() {
        let kept = store.readJson(ConfigClient.file)
        guard let served = ServedConfig.parse(kept?["served"]) else { return }
        raw = kept?.obj("served")
        set(served)
    }

    /// Keeps what is served for the next launch, once storage is allowed: it is written only while consent is
    /// granted.
    package func keep() {
        guard let r = raw else { return }
        store.writeJson(ConfigClient.file, ["served": .object(r)])
    }

    /// Reads the configuration again, unless it is fresh; one read at a time. [done] is told when it is read.
    package func refresh(force: Bool = false, done: (() -> Void)? = nil) {
        if closed || (!force && !stale) {
            done?()
            return
        }
        if let d = done { waiting.append(d) }
        if inFlight { return }
        inFlight = true
        var headers: [String: String] = [:]
        headers["Authorization"] = "Bearer \(writeKey)"
        headers["Accept"] = "application/json"
        headers["User-Agent"] = "\(sdkLibraryName)/\(libraryVersion)"
        if let rev = current.rev, raw != nil { headers["If-None-Match"] = "\"\(rev)\"" }
        http.get(url, headers) { [weak self] answer, error in
            guard let self = self else { return }
            self.scheduler.post { self.answered(answer, error) }
        }
    }

    private func answered(_ answer: HttpAnswer?, _ error: Error?) {
        inFlight = false
        defer {
            let w = waiting
            waiting.removeAll()
            for f in w { f() }
        }
        if !closed { handle(answer, error) }
    }

    private func handle(_ answer: HttpAnswer?, _ error: Error?) {
        guard let answer = answer else {
            log?(
                "the configuration could not be read (\(error.map { "\($0)" } ?? "no answer")); "
                    + "\(raw == nil ? "contract 1" : "the kept one") stands")
            return
        }
        switch answer.status {
        case 200:
            fetchedAtMicros = clock.nowMicros()
            guard let body = try? Json.decode(answer.body) else { return }
            guard let served = ServedConfig.parse(body), let doc = body.object else {
                log?("the configuration served is not one this SDK reads; contract 1 stands")
                return
            }
            raw = doc
            keep()
            set(served)
        case 304:
            fetchedAtMicros = clock.nowMicros()
        case 404, 405:
            // A collector that predates the configuration reads contract 1.
            fetchedAtMicros = clock.nowMicros()
            raw = ConfigClient.contract1Document()
            keep()
            set(ServedConfig.contract1)
        case 401:
            log?("the write key was refused reading the configuration; sending stops until the app starts again")
            onHalt?()
        default:
            log?("the configuration answered \(answer.status); the kept one stands")
        }
    }

    /// The collector refused a field it does not read: it reads contract 1 until its configuration says otherwise,
    /// which is read again now.
    package func refused() {
        raw = ConfigClient.contract1Document()
        keep()
        set(ServedConfig.contract1)
        fetchedAtMicros = nil
        refresh(force: true)
    }

    private func set(_ served: ServedConfig) {
        let was = current
        current = served
        // The revision signs everything a configuration says.
        if was.rev != served.rev || was.contract != served.contract { onChange?(served) }
    }

    package func close() {
        closed = true
    }

    /// What is kept for a collector that answered 404: contract 1, which the next launch then starts with too, rather
    /// than with a later contract a region rolled back past.
    package static func contract1Document() -> JSONObject {
        [
            "v": 1,
            "contract": 1,
            "clicks": .object(JSONObject()),
            "custom_events": true,
            "screen_properties": true,
        ]
    }
}
