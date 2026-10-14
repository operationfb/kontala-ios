/// What the platform measured of a screen, on the main thread and within its one monotonic clock, for the screen it
/// names: the number the platform gave it as it was shown, which the core told `SpeedPlugin.shown`.
package enum SpeedSignal {
    /// The screen's first frame: a cold start's first screen timed from the process's start ([launch]), a pushed one
    /// from its navigation's start, and from the last tap on the screen before, where one came within three seconds of
    /// it.
    case firstFrame(screen: Int, launch: Bool, fcpMs: Int64?, invMs: Int64?)

    /// The frame after the app said the screen was fully displayed, timed as its first frame was.
    case ready(screen: Int, lcpMs: Int64)

    /// A tap on the screen, counted as it happens: its time is told once its frame is drawn.
    case tapped(screen: Int)

    /// A tap, from its end to the first frame drawn after its handlers ran.
    case interaction(
        screen: Int, latencyMs: Int64, processingMs: Int64, presentationMs: Int64, role: String?, path: String?)

    /// Every frame drawn for the screen so far, those that missed the display's budget and those over 700 ms.
    case frames(screen: Int, total: Int64, slow: Int64, frozen: Int64)

    /// A screen that ended has had every frame it drew reported, and every tap on it its frame.
    case settled(screen: Int)

    package var screen: Int {
        switch self {
        case .firstFrame(let s, _, _, _), .ready(let s, _), .tapped(let s), .interaction(let s, _, _, _, _, _),
            .frames(let s, _, _, _), .settled(let s):
            return s
        }
    }
}

/// How fast each screen view was, as a `page_speed` row filed under its view, the Flutter SDK's (friction/speed.dart)
/// and the Android SDK's: sent when the view ends and as the app is hidden, and again when a value changed. Each value
/// is the web's field for the same idea, measured on a screen:
/// - **`fcp_ms`, time to initial display:** a pushed screen's (`soft`) from its navigation's start to its first frame,
///   a cold start's first screen's (`nav: launch`) from the process's start.
/// - **`lcp_ms`, time to full display:** to the frame after the app calls `Kontala.screenReady()`, the same way.
/// - **`inp_ms`, web-vitals' rule over the view's taps:** each from its end to the first frame after it, the ten
///   longest kept and the one at `min(count - 1, interactions / 50)` taken, with its processing, its presentation and
///   its control.
/// - **`inv_ms`, Datadog's interaction to next view:** from the last tap on the screen before, within 3 s, to this
///   screen's first frame.
/// - **`frames`:** every frame drawn while it was on show, those that missed the display's budget and those over
///   700 ms.
///
/// `supported` says which values were measured; a screen never has a TTFB or a CLS.
package final class SpeedPlugin: KontalaPlugin {
    package let key = "speed"

    /// How many of a view's longest interactions are kept, as web-vitals keeps them.
    package static let longest = 10

    /// How many views that ended are kept for what is still measured of them.
    package static let endedKept = 4

    /// How many signals are held for a screen whose view has not opened yet.
    package static let earlyKept = 64

    private weak var ctx: PluginContext?

    private struct Interaction {
        let latency: Int64
        let processing: Int64
        let presentation: Int64
        let role: String?
        let path: String?
    }

    private final class ViewSpeed {
        let view: CapturedEvent
        let screen: Int
        var framed = false
        var launch = false
        var fcp: Int64?
        var lcp: Int64?
        var inv: Int64?
        var interactions = 0
        var longest: [Interaction] = []
        var frames: Int64 = 0
        var slow: Int64 = 0
        var frozen: Int64 = 0
        var sent: String?
        var trigger: String?
        /// Whether it ended and was sent with every frame it drew.
        var settled = false

        init(_ view: CapturedEvent, _ screen: Int) {
            self.view = view
            self.screen = screen
        }

        func row(_ trigger: String?) -> JSONObject {
            let i = longest.isEmpty ? nil : longest[min(longest.count - 1, interactions / 50)]
            let soft = !launch && fcp != nil
            var o = JSONObject()
            if let t = trigger { o["trigger"] = .string(t) }
            if launch { o["nav"] = "launch" }
            if let v = fcp { o["fcp_ms"] = .int(v) }
            if let v = lcp { o["lcp_ms"] = .int(v) }
            if soft { o["soft"] = true }
            if let i = i {
                o["inp_ms"] = .int(i.latency)
                var inp: JSONObject = [
                    "type": "pointer", "processing_ms": .int(i.processing), "presentation_ms": .int(i.presentation),
                ]
                if let r = i.role { inp["role"] = .string(r) }
                if let p = i.path { inp["path"] = .string(p) }
                o["inp"] = .object(inp)
            }
            o["interactions"] = .int(Int64(interactions))
            if let v = inv { o["inv_ms"] = .int(v) }
            if frames > 0 { o["frames"] = ["total": .int(frames), "slow": .int(slow), "frozen": .int(frozen)] }
            var supported: [JSON] = []
            if fcp != nil { supported.append("fcp") }
            if lcp != nil { supported.append("lcp") }
            supported.append("inp")
            if soft { supported.append("soft") }
            if frames > 0 { supported.append("frames") }
            if inv != nil { supported.append("inv") }
            o["supported"] = .array(supported)
            return o
        }

        /// What the row says, but what triggered it: a value changed when this did.
        func key() -> String { Json.encode(row(nil)) }
    }

    private var current: ViewSpeed?
    private var ended: [ViewSpeed] = []
    private var shownScreen = 0

    /// What was measured of the screen numbered last before its view opened, which it is applied to as it does.
    private var early: [SpeedSignal] = []

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        context.onViewStart { [weak self] in self?.started($0) }
        context.onViewEnd { [weak self] in self?.end($0, "view") }
        context.onHide { [weak self] in
            guard let self = self, let v = self.current else { return }
            self.send(v, "hide")
        }
    }

    private var on: Bool {
        guard let ctx = ctx else { return false }
        return ctx.options.friction && ctx.captures(.friction) && ctx.served.contract >= 2
    }

    /// The platform showed its screen numbered [screen]: the view it opens is that screen's.
    package func shown(_ screen: Int) {
        if screen != shownScreen { early.removeAll() }
        shownScreen = screen
    }

    private func started(_ view: CapturedEvent) {
        let v = ViewSpeed(view, shownScreen)
        current = v
        let held = early
        early.removeAll()
        for s in held where s.screen == v.screen { apply(v, s) }
    }

    package func measured(_ s: SpeedSignal) {
        let v = current.flatMap { $0.screen == s.screen ? $0 : nil } ?? ended.first { $0.screen == s.screen }
        guard let view = v else {
            // Its view has not opened yet.
            if s.screen == shownScreen && early.count < SpeedPlugin.earlyKept { early.append(s) }
            return
        }
        apply(view, s)
    }

    private func apply(_ v: ViewSpeed, _ s: SpeedSignal) {
        switch s {
        case .firstFrame(_, let launch, let fcp, let inv):
            if v.framed { return }
            v.framed = true
            v.launch = launch
            v.fcp = fcp
            v.inv = inv
        case .ready(_, let lcp):
            if v.lcp == nil { v.lcp = lcp }
        case .tapped:
            v.interactions += 1
        case .interaction(_, let latency, let processing, let presentation, let role, let path):
            v.longest.append(
                Interaction(
                    latency: latency, processing: processing, presentation: presentation, role: role, path: path))
            // Stable, as Kotlin's sortByDescending is: of two as long, the earlier stays first.
            v.longest = v.longest.enumerated().sorted { a, b in
                a.element.latency != b.element.latency ? a.element.latency > b.element.latency : a.offset < b.offset
            }.map(\.element)
            if v.longest.count > SpeedPlugin.longest { v.longest.removeLast() }
        case .frames(_, let total, let slow, let frozen):
            v.frames = total
            v.slow = slow
            v.frozen = frozen
        case .settled:
            // A view that ended is sent again once, when every frame it drew has been reported and every tap of it
            // has its frame, rather than at each report.
            if v !== current && !v.settled {
                v.settled = true
                if v.sent != nil && v.key() != v.sent { send(v, v.trigger ?? "view") }
            }
        }
    }

    private func end(_ view: CapturedEvent, _ trigger: String) {
        guard let v = current, v.view === view else { return }
        send(v, trigger)
        ended.insert(v, at: 0)
        while ended.count > SpeedPlugin.endedKept { ended.removeLast() }
    }

    private func send(_ v: ViewSpeed, _ trigger: String) {
        guard on, let ctx = ctx else { return }
        let key = v.key()
        if key == v.sent { return }
        v.sent = key
        v.trigger = trigger
        ctx.emit("page_speed", ["speed": .object(v.row(trigger))], viewOf: v.view.id, measure: true)
    }
}
