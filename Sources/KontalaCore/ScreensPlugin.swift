/// Screen views: the only plugin that opens views, as `PageViewPlugin` is the tag's, and the Flutter SDK's
/// `ScreensPlugin` line for line.
///
/// A screen is a `page_view` of `app://<app id>/<name>`, deduplicated on its name and query as the tag's page view is
/// on `href`. What the app declares about it (a page type, properties, the properties every screen carries) rides on
/// its page view while that is unsent: declared during a navigation, on the next one.
package final class ScreensPlugin: KontalaPlugin {
    package let key = "screens"

    private weak var ctx: PluginContext?

    /// The screen on show.
    package private(set) var screen: ScreenView?

    private var view: CapturedEvent?
    private var launch: CapturedEvent?
    private var launchAtMicros: Int64?
    private var navigating = false
    private var pendingType: KontalaPageType?
    private var pendingData = JSONObject()
    private var superProperties = JSONObject()

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
    }

    /// A navigation began: what is declared until its screen is shown rides on that screen's page view.
    package func navigationStarted(_ kind: NavigationKind) {
        navigating = true
    }

    /// A navigation settled on the screen already on show.
    package func navigationIdle() {
        navigating = false
        applyPending()
    }

    package func screenShown(_ v: ScreenView) {
        navigating = false
        if let current = screen, v.url == current.url, v.kind != .resume {
            screen = v.route != nil ? v : current
            applyPending()
            return
        }
        if v.link && amendLaunch(v) { return }
        open(v)
    }

    /// Opens the screen on show again, as a session starts: a visit's first row is then a screen view, with an
    /// entrance and a Channel. Without the query of the link that opened the screen: the visitor came back by
    /// themselves, and the campaign had its visit already.
    package func reopen() {
        if let s = screen { open(s.resumed()) }
    }

    private func open(_ v: ScreenView) {
        guard let ctx = ctx else { return }
        let declared = v.declaration
        let type = pendingType ?? declared?.pageType
        var props = superProperties
        if let d = declared?.properties { props.merge(d) }
        props.merge(pendingData)
        pendingType = nil
        pendingData = JSONObject()
        let launched = v.kind == .launch
        let referrer = launched ? ctx.facts?.referrer : nil
        let safe = safeProperties(props, log: ctx.log)
        // iOS gives a cold start's deep link only after the first frame, so the
        // launch view waits as long for it to name its screen. Android never.
        let settle: Int64? = launched && !v.link && ctx.facts?.isIOS == true ? ctx.nowMicros() + 3_000_000 : nil
        let from = screen?.name
        var screenJson = ScreensPlugin.screenJson(v, referrer)
        if let t = v.title { screenJson["title"] = .string(t) }
        screenJson["navigation"] = .string(v.kind.wire)
        if let f = from { screenJson["from"] = .string(f) }
        var fields = JSONObject()
        fields["screen"] = .object(screenJson)
        if let t = type { fields["page_type"] = .string(t.wire) }
        if let s = safe { fields["properties"] = .object(s) }
        let e = ctx.emit("page_view", fields, startsView: true, screen: v.name, settleUntilMicros: settle)
        screen = v
        guard let event = e else { return }
        view = event
        if launched {
            launch = event
            launchAtMicros = ctx.nowMicros()
        }
    }

    private static func screenJson(_ v: ScreenView, _ referrer: String?) -> JSONObject {
        var o: JSONObject = ["name": .string(v.name)]
        if let q = v.query { o["query"] = .string(q) }
        if let r = referrer, r.utf16.count <= Limits.maxURL { o["referrer"] = .string(r) }
        return o
    }

    /// A link delivered after the first frame names the launch view's screen, while that is still unsent and nothing
    /// else has opened, so the campaign is on the visit's entrance.
    private func amendLaunch(_ v: ScreenView) -> Bool {
        guard let ctx = ctx, let l = launch, let at = launchAtMicros, l === view else { return false }
        if ctx.nowMicros() - at > 3_000_000 { return false }
        let type = pendingType ?? v.declaration?.pageType
        let props = v.declaration?.properties
        let log = ctx.log
        let ok = ctx.amend(l) { f in
            let was = f.obj("screen")
            var s = ScreensPlugin.screenJson(v, nil)
            if let t = v.title { s["title"] = .string(t) }
            // Still the launch: the link named the screen it opened on.
            if let n = was?["navigation"] { s["navigation"] = n }
            f["screen"] = .object(s)
            if let t = type { f["page_type"] = .string(t.wire) }
            if let p = props {
                var merged = f.obj("properties") ?? JSONObject()
                merged.merge(p)
                if let safe = safeProperties(merged, log: log) { f["properties"] = .object(safe) }
            }
        }
        if !ok { return false }
        l.settleUntilMicros = nil
        pendingType = nil
        screen = v
        ctx.renameScreen(v.name)
        applyPending()
        return true
    }

    private func applyPending() {
        if let t = pendingType {
            pendingType = nil
            pageType(t)
        }
        if !pendingData.isEmpty {
            let data = pendingData
            pendingData = JSONObject()
            screenData(data)
        }
    }

    /// `Kontala.pageType`: the screen's own page type, which always wins.
    package func pageType(_ type: KontalaPageType) {
        guard let ctx = ctx else { return }
        guard !navigating, let v = view else {
            pendingType = type
            return
        }
        if ctx.amend(v, { $0["page_type"] = .string(type.wire) }) { return }
        if ctx.served.contract >= 2 {
            // Too late to ride on its screen view: a row of its own, filed under
            // it, which the warehouse prefers to anything declared before.
            ctx.emit("page_type", ["page_type": .string(type.wire)])
            return
        }
        ctx.log(
            "a page type was declared after its screen view was sent, and was dropped: declare it as the screen opens")
    }

    /// `Kontala.screenData`: properties the screen view carries as the screen's data layer.
    package func screenData(_ properties: JSONObject) {
        guard let ctx = ctx else { return }
        guard !navigating, let v = view else {
            pendingData.merge(properties)
            return
        }
        let log = ctx.log
        let ok = ctx.amend(v) { f in
            var merged = f.obj("properties") ?? JSONObject()
            merged.merge(properties)
            if let safe = safeProperties(merged, log: log) { f["properties"] = .object(safe) }
        }
        if !ok {
            ctx.log("screen data came after its screen view was sent, and was dropped: pass it as the screen opens")
        }
    }

    /// `Kontala.register`: properties every screen view carries from now on, the one on show too while it is unsent.
    package func register(_ properties: JSONObject) {
        superProperties.merge(properties)
        guard let ctx = ctx, let v = view else { return }
        let log = ctx.log
        _ = ctx.amend(v) { f in
            var merged = properties
            merged.merge(f.obj("properties") ?? JSONObject())
            if let safe = safeProperties(merged, log: log) { f["properties"] = .object(safe) }
        }
    }

    package func unregister(_ key: String) {
        superProperties.removeValue(forKey: key)
    }

    /// A screen declared itself after its screen view was emitted, as one whose properties change on its first frames
    /// does.
    package func declared(_ route: RouteRef, _ d: ScreenDeclaration) {
        guard let ctx = ctx, let s = screen, let v = view, s.route?.same(route) == true else { return }
        let log = ctx.log
        _ = ctx.amend(v) { f in
            if let t = d.pageType { f["page_type"] = .string(t.wire) }
            if let props = d.properties {
                var merged = f.obj("properties") ?? JSONObject()
                merged.merge(props)
                if let safe = safeProperties(merged, log: log) { f["properties"] = .object(safe) }
            }
        }
    }

    /// The launch view's referrer, once the platform has said what it is.
    package func factsLoaded() {
        guard let ctx = ctx, let l = launch, let referrer = ctx.facts?.referrer else { return }
        if referrer.utf16.count > Limits.maxURL { return }
        _ = ctx.amend(l) { f in
            if var s = f.obj("screen") {
                s["referrer"] = .string(referrer)
                f["screen"] = .object(s)
            }
        }
    }
}

extension JSONObject {
    /// Sets every entry of [other] here, as a map's `putAll` does: a key already here keeps its place.
    package mutating func merge(_ other: JSONObject) {
        for (k, v) in other { self[k] = v }
    }
}
