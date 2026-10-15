/// The kinds contract 2 adds: what an app measures of a screen, and a page type declared after its screen view was
/// sent.
package let contract2Kinds: Set<String> = [
    "scroll_depth",
    "swipe",
    "page_speed",
    "js_error",
    "rage_click",
    "dead_click",
    "page_restore",
    "view_time",
    "page_type",
]

/// The fields contract 2 adds to a screen view: its title, how it was reached and the screen before it.
private let contract2Screen: Set<String> = ["title", "navigation", "from"]

/// The fields contract 2 adds to a tap: its trigger, form and search.
private let contract2Click: Set<String> = ["trigger", "form", "search"]

/// The kinds contract 3 adds: a change of what the visitor answered in a consent manager.
package let contract3Kinds: Set<String> = ["consent_change"]

/// The field contract 3 adds to every event: what the visitor had answered.
private let contract3Signals = "consent_signals"

/// Writes events as the Events API reads them (docs/openapi/events-v1.yaml).
///
/// The API's decoder refuses an unknown field and fails the whole request with it, so what is written depends on the
/// contract the region's collector has said it reads: 1 until its configuration says otherwise. What a later contract
/// adds is left out of a request for one that reads an earlier: its kinds whole, and its fields of an event the
/// earlier has.
package final class WireEncoder {
    private let clock: Clock
    package var contract: Int

    package init(clock: Clock, contract: Int = 1) {
        self.clock = clock
        self.contract = contract
    }

    /// A request body: the batch's commonest context, and each event with only what differs from it, or nil when
    /// nothing of [events] is written at this contract. `sent_at` is added at send time.
    package func encodeBatch(_ events: [CapturedEvent]) -> JSONObject? {
        let written = events.filter {
            (contract >= 2 || !contract2Kinds.contains($0.kind)) && (contract >= 3 || !contract3Kinds.contains($0.kind))
        }
        if written.isEmpty { return nil }
        let batch = WireEncoder.commonest(written)
        return [
            "context": .object(contextJson(batch)),
            "events": .array(written.map { .object(encodeEvent($0, batch)) }),
        ]
    }

    package func contextJson(_ c: ContextSnapshot) -> JSONObject {
        var o = JSONObject()
        o["app"] = .object(c.appJson(withScreen: false, contract: contract))
        if let v = c.locale { o["locale"] = .string(v) }
        if let v = c.timezone { o["timezone"] = .string(v) }
        if let d = c.displayJson() { o["display"] = .object(d) }
        o["library"] = .object(c.libraryJson())
        if let v = c.userAgent { o["user_agent"] = .string(v) }
        if contract >= 2 {
            if let os = c.osJson() { o["os"] = .object(os) }
            o["device"] = .object(c.deviceJson())
        }
        return o
    }

    package func encodeEvent(_ e: CapturedEvent, _ batch: ContextSnapshot) -> JSONObject {
        var m = JSONObject()
        m["id"] = .string(e.id)
        m["event"] = .string(e.kind)
        m["timestamp"] = .string(rfc3339(clock.sendTime(e.atMicros, e.monotonic)))
        if let v = e.device { m["device"] = .string(v) }
        if let v = e.session { m["session"] = .string(v) }
        if let v = e.user { m["user"] = .string(v) }
        if let v = e.org { m["org"] = .string(v) }
        m["consent"] = .string(e.consent)
        if contract >= 3, let s = e.signals { m[contract3Signals] = .object(s.toJson()) }
        if !e.isPageView, let v = e.view { m["view"] = .string(v) }
        for (k, v) in e.fields {
            if v.isNull { continue }
            if contract < 2 && e.kind == "click" && contract2Click.contains(k) { continue }
            if contract < 2, k == "screen", let screen = v.object {
                m[k] = .object(WireEncoder.contract1Screen(screen))
            } else {
                m[k] = v
            }
        }
        let own = override(e, batch)
        if !own.isEmpty { m["context"] = .object(own) }
        return m
    }

    /// What the event's context states over the batch's: the API overrides the batch's `app` field by field and every
    /// other object whole, so an event whose device differs from the batch's states all of its own, which is how a
    /// batch holding granted and other events keeps the ids on the granted alone.
    private func override(_ e: CapturedEvent, _ batch: ContextSnapshot) -> JSONObject {
        let c = e.context
        var out = JSONObject()
        var app = JSONObject()
        if c.appId != batch.appId { app["id"] = .string(c.appId) }
        if let v = c.appVersion, v != batch.appVersion { app["version"] = .string(v) }
        if let v = c.appBuild, v != batch.appBuild { app["build"] = .string(v) }
        if !e.isPageView, let v = c.screen { app["screen"] = .string(v) }
        if contract >= 2, let v = c.appMode, v != batch.appMode { app["mode"] = .string(v) }
        if !app.isEmpty { out["app"] = .object(app) }
        if let v = c.locale, v != batch.locale { out["locale"] = .string(v) }
        if let v = c.timezone, v != batch.timezone { out["timezone"] = .string(v) }
        if c.displayWidth != batch.displayWidth || c.displayHeight != batch.displayHeight {
            if let d = c.displayJson() { out["display"] = .object(d) }
        }
        if c.libraryName != batch.libraryName || c.libraryVersion != batch.libraryVersion {
            out["library"] = .object(c.libraryJson())
        }
        if let v = c.userAgent, v != batch.userAgent { out["user_agent"] = .string(v) }
        if contract >= 2 {
            if let os = c.osJson(), Json.encode(os) != Json.encode(batch.osJson().map { JSON.object($0) } ?? .null) {
                out["os"] = .object(os)
            }
            let device = c.deviceJson()
            if Json.encode(device) != Json.encode(batch.deviceJson()) { out["device"] = .object(device) }
        }
        return out
    }

    /// The snapshot most events of a batch share, screens aside: the first met of two as common as each other.
    package static func commonest(_ events: [CapturedEvent]) -> ContextSnapshot {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var byKey: [String: ContextSnapshot] = [:]
        for e in events {
            let c = e.context.withScreen(nil)
            let k = Json.encode(c.toJson())
            if counts[k] == nil {
                order.append(k)
                byKey[k] = c
            }
            counts[k, default: 0] += 1
        }
        var best = order[0]
        for k in order where counts[k]! > counts[best]! { best = k }
        return byKey[best]!
    }

    private static func contract1Screen(_ screen: JSONObject) -> JSONObject {
        screen.filter { k, _ in !contract2Screen.contains(k) }
    }

    /// [body], sealed at a later contract than its collector reads, written at the contract before: a body of contract
    /// 3 at contract 2, its kinds left out whole and every event's signals, and a body of contract 2 at contract 1,
    /// contract 2's kinds left out whole, and its fields of every other event and of the contexts. A collector refusing
    /// the copy too is sent the copy's copy, so a region rolled back loses only what it cannot read. Nil when nothing
    /// was left out, which makes a refusal of [body] an SDK fault; its events may be none, when every one was of a
    /// later contract.
    package static func downgrade(_ body: JSONObject) -> JSONObject? { toContract2(body) ?? toContract1(body) }

    private static func toContract2(_ body: JSONObject) -> JSONObject? {
        var changed = false
        var events: [JSON] = []
        for raw in body.list("events") ?? [] {
            guard var e = raw.object else { continue }
            if let k = e.str("event"), contract3Kinds.contains(k) {
                changed = true
                continue
            }
            if e.removeValue(forKey: contract3Signals) != nil { changed = true }
            events.append(.object(e))
        }
        if !changed { return nil }
        var out = body
        out["events"] = .array(events)
        return out
    }

    private static func toContract1(_ body: JSONObject) -> JSONObject? {
        var changed = false
        func context(_ c: JSON?) -> JSONObject? {
            guard var out = c?.object else { return nil }
            if out.removeValue(forKey: "os") != nil { changed = true }
            if out.removeValue(forKey: "device") != nil { changed = true }
            if var app = out.obj("app"), app.contains("mode") {
                app.removeValue(forKey: "mode")
                if app.isEmpty { out.removeValue(forKey: "app") } else { out["app"] = .object(app) }
                changed = true
            }
            return out
        }

        var events: [JSON] = []
        for raw in body.list("events") ?? [] {
            guard var e = raw.object else { continue }
            let kind = e.str("event")
            if let k = kind, contract2Kinds.contains(k) {
                changed = true
                continue
            }
            if kind == "click" {
                for f in contract2Click where e.removeValue(forKey: f) != nil { changed = true }
            }
            if let screen = e.obj("screen"), screen.keys.contains(where: { contract2Screen.contains($0) }) {
                e["screen"] = .object(contract1Screen(screen))
                changed = true
            }
            if let own = context(e["context"]) {
                if own.isEmpty { e.removeValue(forKey: "context") } else { e["context"] = .object(own) }
            }
            events.append(.object(e))
        }
        let batchContext = context(body["context"])
        if !changed { return nil }
        var out = body
        if let c = batchContext { out["context"] = .object(c) }
        out["events"] = .array(events)
        return out
    }
}
