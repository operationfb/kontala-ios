import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// sdk/testdata/vectors.json: the answers every one of Kontala's app SDKs gives for the rules that are no platform's
/// own, which the Flutter SDK's suite writes. This suite holds the Swift port to every one of them.
final class SdkVectorsTests: XCTestCase {
    private let v = repoJson("sdk/testdata/vectors.json")

    private func cases(_ section: String) -> [JSONObject] {
        (v.list(section) ?? []).map { $0.object! }
    }

    private func check(
        _ c: JSONObject, _ got: JSON, key: String = "want", file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let normal = try! Json.decode(Json.encode(got))
        let want = c[key] ?? .null
        if !jsonEquals(normal, want) {
            let what = c["note"].map { Json.encode($0) } ?? c["in"].map { Json.encode($0) } ?? Json.encode(.object(c))
            XCTFail("\(what):\n  got  \(Json.encode(normal))\n  want \(Json.encode(want))", file: file, line: line)
        }
    }

    private func int(_ c: JSONObject, _ key: String) -> Int { Int(c[key]!.number!) }

    func testCollapse() {
        for c in cases("collapse") { check(c, .string(collapse(c.str("in")!, int(c, "max")))) }
    }

    func testPrintableText() {
        for c in cases("printable_text") { check(c, .string(printableText(c.str("in")!, int(c, "max")))) }
    }

    func testCutBytes() {
        for c in cases("cut_bytes") { check(c, .string(cutBytes(c.str("in")!, int(c, "max")))) }
    }

    func testCutRunes() {
        for c in cases("cut_runes") { check(c, .string(cutRunes(c.str("in")!, int(c, "max")))) }
    }

    func testPrintable() {
        for c in cases("printable") { check(c, .bool(printable(c.str("in")!))) }
    }

    func testCanonicalEventName() {
        for c in cases("canonical_event_name") {
            let n = canonicalEventName(c.str("in")!)
            check(c, ["canonical": .string(n), "reserved": .bool(reservedEventNames.contains(n))])
        }
    }

    func testCleanQuery() {
        for c in cases("clean_query") { check(c, JSON(cleanQuery(c.str("in")!))) }
    }

    func testJsonSafe() {
        for c in cases("json_safe") {
            check(c, safeProperties(c.obj("in")).map { .object($0) } ?? .null)
        }
    }

    func testUserAgent() {
        for c in cases("user_agent") {
            var m: JSONObject = ["appId": "com.example.shop"]
            m.merge(c.obj("facts")!)
            let facts = PlatformFacts.fromMap(m)
            let ua = buildUserAgent(
                facts, c.str("sdk_version")!, model: c["model"]!.bool!, osVersion: c["os_version"]!.bool!)
            check(c, .string(ua))
        }
    }

    func testRfc3339() {
        for c in cases("rfc3339") { check(c, .string(rfc3339(c.long("micros")!))) }
    }

    func testUuidV7() {
        let shape = Pattern("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        for c in cases("uuid_v7") {
            let id = Ids.uuidV7(c.long("ms")!)
            XCTAssertTrue(shape.matches(id), id)
            // The millisecond is the first 48 bits; the rest is random.
            check(c, .string(String(id.prefix(13))))
        }
    }

    func testSafeIds() {
        for c in cases("safe_id") { check(c, .bool(Ids.safeId.matches(c.str("in")!))) }
        for c in cases("safe_principal_id") { check(c, .bool(Ids.safePrincipalId.matches(c.str("in")!))) }
    }

    func testNamedPrincipal() {
        for c in cases("named_principal") {
            let own = c.obj("own")!
            let named = c.obj("named")!
            let web = c.obj("web") ?? JSONObject()
            let p = Principal()
            p.set(user: own.str("user"), org: own.str("org"))
            p.setWeb(user: web.str("user"), org: web.str("org"))
            let (user, org) = namedPrincipal(p, user: named.str("user"), org: named.str("org"))
            check(c, ["user": JSON(user), "org": JSON(org)])
        }
    }

    func testWebOrigin() {
        for c in cases("web_origin") {
            guard let w = WebOrigin.parse(c.str("origin")!, cookieDomain: c.str("cookie_domain")) else {
                check(c, .null)
                continue
            }
            let matches: [JSON] = (c.list("urls") ?? []).map { .bool(w.matches($0.string)) }
            check(
                c,
                [
                    "value": .string(w.value), "cookie_domain": JSON(w.cookieDomain), "url": .string(w.url),
                    "secure": .bool(w.secure), "matches": .array(matches),
                ])
        }
    }

    func testIdentity() {
        for c in cases("identity") {
            let identity = Identity(store: FileStore(baseDir: nil), timeoutMillis: c.long("timeout_ms")!)
            var names: [String: String] = [:]
            for step in (c.list("steps") ?? []).map({ $0.object! }) {
                if step["forget"] == .bool(true) {
                    identity.forget()
                    continue
                }
                let presence: Presence
                switch step.str("presence")! {
                case "here": presence = .here
                case "leaving": presence = .leaving
                default: presence = .away
                }
                let ids = identity.resolve(step.long("at")!, presence)
                if names[ids.session] == nil { names[ids.session] = "session-\(names.count + 1)" }
                check(step, ["session": .string(names[ids.session]!), "rotated": .bool(ids.rotated)])
            }
        }
    }

    func testDeviceIds() {
        for c in cases("device_ids") {
            let ids = DeviceIds.fromMap(c.obj("in")!)
            check(
                c,
                ["ids": .object(ids.idsJson()), "ad_tracking": JSON(ids.adTracking), "empty": .bool(ids.isEmpty)])
        }
    }

    private func served(_ c: ServedConfig?) -> JSON {
        guard let it = c else { return .null }
        var scroll = JSON.null
        if let s = it.scroll {
            scroll = [
                "settle_ms": .int(Int64(s.settleMs)),
                "max_wait_ms": .int(Int64(s.maxWaitMs)),
                "swipes": [
                    "per_view": .int(Int64(s.swipes.perView)),
                    "per_page": .int(Int64(s.swipes.perPage)),
                    "min_px": .int(Int64(s.swipes.minPx)),
                    "max_ms": .int(Int64(s.swipes.maxMs)),
                    "axis_ratio": .double(s.swipes.axisRatio),
                    "edge_px": .int(Int64(s.swipes.edgePx)),
                ],
            ]
        }
        var friction = JSON.null
        if let f = it.friction {
            friction = [
                "errors_per_view": .int(Int64(f.errorsPerView)),
                "errors_per_page": .int(Int64(f.errorsPerPage)),
                "error_click_ms": .int(Int64(f.errorClickMs)),
                "rage_clicks": .int(Int64(f.rageClicks)),
                "rage_window_ms": .int(Int64(f.rageWindowMs)),
                "rage_radius_px": .int(Int64(f.rageRadiusPx)),
                "rage_per_view": .int(Int64(f.ragePerView)),
                "rage_per_page": .int(Int64(f.ragePerPage)),
                "dead_wait_ms": .int(Int64(f.deadWaitMs)),
                "dead_late_ms": .int(Int64(f.deadLateMs)),
                "dead_per_view": .int(Int64(f.deadPerView)),
                "dead_per_page": .int(Int64(f.deadPerPage)),
                "speed_settle_ms": .int(Int64(f.speedSettleMs)),
                "speed_max_wait_ms": .int(Int64(f.speedMaxWaitMs)),
                "speed_rows_per_view": .int(Int64(f.speedRowsPerView)),
                "restores_per_page": .int(Int64(f.restoresPerPage)),
            ]
        }
        return [
            "contract": .int(Int64(it.contract)),
            "rev": JSON(it.rev),
            "clicks": .bool(it.clicks),
            "custom_events": .bool(it.customEvents),
            "screen_properties": .bool(it.screenProperties),
            "scroll": scroll,
            "friction": friction,
            "web_views": .array(
                it.webOrigins.map { ["origin": .string($0.value), "cookie_domain": JSON($0.cookieDomain)] }),
        ]
    }

    func testConfig() {
        for c in cases("config") { check(c, served(ServedConfig.parse(c["in"]))) }
    }

    func testWire() throws {
        for c in cases("wire") {
            let want = c.obj("want")!
            for contract in [1, 2] {
                let events = try (c.list("events") ?? []).map { try CapturedEvent.fromStored($0.object!) }
                let body = WireEncoder(clock: Clock(), contract: contract).encodeBatch(events)
                check(want, body.map { .object($0) } ?? .null, key: "\(contract)")
            }
        }
    }

    func testDowngrade() {
        for c in cases("downgrade") {
            check(c, WireEncoder.downgrade(c.obj("in")!).map { .object($0) } ?? .null)
        }
    }

    func testDepth() {
        for c in cases("depth") {
            let d = Depth()
            for r in c.list("readings") ?? [] {
                let n = r.array!.map { $0.number! }
                d.record(Reading(n[0], n[1], n[2]))
            }
            let m = d.measure()
            check(
                c,
                m.map {
                    [
                        "depth_px": .int($0.depthPx), "height_px": .int($0.heightPx),
                        "viewport_px": .int($0.viewportPx), "depth_pct": .int($0.depthPct),
                    ]
                } ?? .null)
        }
        for c in cases("depth_percent") {
            check(c, .int(depthPercent(Int64(c["px"]!.number!), Int64(c["height"]!.number!))))
        }
        func measured(_ raw: JSON?) -> Measured? {
            guard let a = raw?.array else { return nil }
            let n = a.map { Int64($0.number!) }
            return Measured(n[0], n[1], n[2])
        }
        for c in cases("deeper") { check(c, .bool(deeper(measured(c["now"])!, measured(c["sent"])))) }
    }

    func testEverySectionIsRead() {
        let read: Set<String> = [
            "_comment", "collapse", "printable_text", "cut_bytes", "cut_runes", "printable", "canonical_event_name",
            "clean_query", "json_safe", "user_agent", "rfc3339", "uuid_v7", "safe_id", "safe_principal_id",
            "named_principal", "web_origin", "identity", "device_ids", "config", "wire", "downgrade", "depth",
            "depth_percent", "deeper",
        ]
        XCTAssertEqual(
            Set(v.keys).subtracting(read), [], "a section of sdk/testdata/vectors.json this suite does not read")
    }
}
