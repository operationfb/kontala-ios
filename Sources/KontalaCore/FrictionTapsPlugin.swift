/// A tap as the friction rules read it: what was under the finger, read at the press, and told at its end, the
/// Flutter SDK's `_Press`.
package struct FrictionPress {
    /// What it was on: its control, else what is there, described as a tap's element is.
    package var hit: TapTarget
    /// The control, where it was on one: what it acted on.
    package var target: TapTarget?
    /// The control as an identity a second tap is compared by: a view's [RouteRef], held weakly.
    package var control: AnyObject?
    /// A field or text that can be selected, never part of a rage tap: a triple tap selects a paragraph.
    package var excluded: Bool
    /// Where, in points.
    package var x: Double
    package var y: Double
    package var input: String
    /// What the app showed at the press, for a dead tap's candidate and a burst's first tap; nil where not taken.
    package var fingerprint: Int64?

    package init(
        hit: TapTarget, target: TapTarget?, control: AnyObject?, excluded: Bool, x: Double, y: Double, input: String,
        fingerprint: Int64?
    ) {
        self.hit = hit
        self.target = target
        self.control = control
        self.excluded = excluded
        self.x = x
        self.y = y
        self.input = input
        self.fingerprint = fingerprint
    }
}

/// Rage taps and dead taps, the web's rage and dead clicks (tag/plugins/friction/clicks.ts), the Flutter SDK's
/// (friction/taps.dart) and the Android SDK's, on the core's queue: the platform reads each tap and what the app shows
/// off its views, and this keeps the rules and their timers.
/// - A rage tap is PostHog's: each tap within the window and the radius (a Manhattan distance) of the one before it,
///   the served number of them, sent when its burst ends: at a tap that breaks the chain, after the window passes with
///   no tap, at a navigation's start or as the app is hidden. It is marked dead when nothing answered it.
/// - A dead tap is a tap on a control that nothing answered within the wait, watched until the late mark: `late` with
///   how late, `none`, `left` as the app was hidden past the wait, or `disabled` at once, for a control the app had
///   disabled. It is dropped when its wait timer fired so late that the queue was blocked, and whatever cannot be told
///   is dropped too, so dead taps are a lower bound, never an invention.
///
/// What answers a tap: a navigation, any screen or dialog opened or closed, the app going inactive or another window
/// taking the key, which coming back says, and what the platform tells ([answered]): a field beginning its editing
/// other than by the press itself, the keyboard showing or going, the screen's scroll view moving. Failing those, a
/// fingerprint of what the app shows, taken at the press and compared at the wait and every second after it.
package final class FrictionTapsPlugin: KontalaPlugin {
    package let key = "friction_taps"

    /// The most taps a rage click counts, as the collector keeps them.
    package static let maxRageTaps = 99

    /// How late a dead tap's wait timer may fire before the tap is dropped: a queue that busy cannot say.
    package static let blockedMs = 250

    /// How soon a tap on the same control is not a dead tap's candidate again.
    package static let debounceMicros: Int64 = 500_000

    /// How often a dead tap's fingerprint is compared again after its wait.
    package static let recheckMicros: Int64 = 1_000_000

    /// The roles a dead tap may be on: what looks tappable and answers in a way the screen shows. A field and a choice
    /// answer in their own state, which no fingerprint of the screen needs to show.
    package static let deadRoles: Set<String> = ["button", "link", "tab", "menuitem", "cell", "image"]

    private weak var ctx: PluginContext?

    private final class Burst {
        let firstX: Double
        let firstY: Double
        let firstAt: Int64
        let hit: TapTarget
        let view: CapturedEvent?
        let fingerprint: Int64?
        var lastX: Double
        var lastY: Double
        var lastAt: Int64
        var taps = 1
        var answered = false
        var stop: () -> Void = {}

        init(_ x: Double, _ y: Double, _ at: Int64, _ hit: TapTarget, _ view: CapturedEvent?, _ fingerprint: Int64?) {
            firstX = x
            firstY = y
            firstAt = at
            self.hit = hit
            self.view = view
            self.fingerprint = fingerprint
            lastX = x
            lastY = y
            lastAt = at
        }
    }

    private final class Candidate {
        let x: Double
        let y: Double
        let at: Int64
        let fields: JSONObject
        let input: String
        let view: CapturedEvent?
        let fingerprint: Int64?
        var overdue = false
        var timer: Cancellable?
        var stop: () -> Void = {}

        init(
            _ x: Double, _ y: Double, _ at: Int64, _ fields: JSONObject, _ input: String, _ view: CapturedEvent?,
            _ fingerprint: Int64?
        ) {
            self.x = x
            self.y = y
            self.at = at
            self.fields = fields
            self.input = input
            self.view = view
            self.fingerprint = fingerprint
        }
    }

    /// What the app shows at a burst's end, where it is known without asking the platform.
    private struct Print {
        let value: Int64?
    }

    private var burst: Burst?
    private var quiet: Cancellable?
    private var candidates: [Candidate] = []
    private var lastControl: AnyObject?
    private var lastControlAt: Int64 = 0
    private var watchers: [(id: Int, f: (Int64) -> Void)] = []
    private var nextWatcher = 0

    /// When the app went inactive, or another window took the key, while it is: which it was is known when it comes
    /// back.
    private var inactiveAt: Int64?
    private var windowAway = false

    /// What the app showed as it was hidden, which the platform read before it said so.
    private var hidePrint: Int64?
    private var rageView = 0
    private var ragePage = 0
    private var deadView = 0
    private var deadPage = 0
    private var bound = false

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        bound = true
        context.onNavigationStart { [weak self] _ in
            self?.answer()
            self?.endBurst(nil)
        }
        context.onRouteChange { [weak self] in self?.answer() }
        context.onHide { [weak self] in self?.hide() }
        context.onLifecycle { [weak self] in self?.lifecycle($0) }
        context.onViewStart { [weak self] _ in
            self?.rageView = 0
            self?.deadView = 0
        }
    }

    package func unbind() {
        bound = false
        quiet?.cancel()
        quiet = nil
        burst?.stop()
        burst = nil
        for c in candidates { drop(c) }
        watchers.removeAll()
    }

    private var rules: FrictionRules? {
        guard let ctx = ctx, ctx.options.friction, ctx.captures(.friction) else { return nil }
        return ctx.served.friction
    }

    private func lifecycle(_ state: AppState) {
        switch state {
        case .inactive: if inactiveAt == nil { inactiveAt = ctx?.elapsedMicros }
        case .resumed: comeBack()
        // The app left: hide decides, and nothing it was before answered.
        case .hidden: break
        }
    }

    /// Another window of the app's took the key from the screen's, or gave it back.
    package func windowFocus(_ focused: Bool) {
        if !focused {
            windowAway = true
            if inactiveAt == nil { inactiveAt = ctx?.elapsedMicros }
        } else if windowAway {
            windowAway = false
            comeBack()
        }
    }

    private func comeBack() {
        guard let at = inactiveAt else { return }
        inactiveAt = nil
        answer(at)
    }

    /// Something on show answered whatever was tapped: a field began its editing, the keyboard showed, a scroll.
    package func answered() { answer() }

    /// What the app showed as it went to the background, read before it said so.
    package func hiding(_ print: Int64?) {
        hidePrint = print
    }

    // Taps.

    package func pressed(_ p: FrictionPress) {
        guard let ctx = ctx, let r = rules else { return }
        let at = ctx.elapsedMicros
        rage(p, at, r)
        dead(p, at, r)
    }

    /// What a row says of the element: never a click type, which is a click's.
    private func fieldsOf(_ t: TapTarget) -> JSONObject {
        var described = t
        described.declared = nil
        return described.toFields()
    }

    // Rage.

    private func rage(_ p: FrictionPress, _ at: Int64, _ r: FrictionRules) {
        if let b = burst, !p.excluded, at - b.lastAt <= Int64(r.rageWindowMs) * 1000,
            abs(p.x - b.lastX) + abs(p.y - b.lastY) <= Double(r.rageRadiusPx)
        {
            b.taps = min(b.taps + 1, FrictionTapsPlugin.maxRageTaps)
            b.lastX = p.x
            b.lastY = p.y
            b.lastAt = at
            armQuiet(r)
            return
        }
        // What the app shows now is what this tap's own fingerprint read at its press.
        endBurst(Print(value: p.fingerprint))
        if p.excluded { return }
        let nb = Burst(p.x, p.y, at, p.hit, ctx?.currentView, p.fingerprint)
        burst = nb
        nb.stop = watch { [weak nb] _ in nb?.answered = true }
        armQuiet(r)
    }

    private func armQuiet(_ r: FrictionRules) {
        quiet?.cancel()
        quiet = ctx?.scheduler.schedule(Int64(r.rageWindowMs) * 1000) { [weak self] in
            guard let self = self else { return }
            self.quiet = nil
            self.endBurst(nil)
        }
    }

    /// Ends the burst in force: sent where it was a rage tap, marked dead unless something answered it or what the app
    /// shows changed, which [now] says where it is known, and the platform is asked for where it is not.
    private func endBurst(_ now: Print?) {
        guard let b = burst else { return }
        burst = nil
        quiet?.cancel()
        quiet = nil
        b.stop()
        guard let r = rules else { return }
        if b.taps < r.rageClicks || rageView >= r.ragePerView || ragePage >= r.ragePerPage { return }
        if b.answered || b.fingerprint == nil {
            sendRage(b, r, answered: true)
            return
        }
        if let now = now {
            sendRage(b, r, answered: now.value != b.fingerprint)
            return
        }
        // Counted now, so a burst ending before the platform answers is held to the same caps.
        rageView += 1
        ragePage += 1
        ctx?.fingerprint { [weak self] print in
            guard let self = self, self.bound else { return }
            self.emitRage(b, answered: print != b.fingerprint)
        }
    }

    private func sendRage(_ b: Burst, _ r: FrictionRules, answered: Bool) {
        if rageView >= r.ragePerView || ragePage >= r.ragePerPage { return }
        rageView += 1
        ragePage += 1
        emitRage(b, answered: answered)
    }

    private func emitRage(_ b: Burst, answered: Bool) {
        var rage: JSONObject = ["clicks": .int(Int64(b.taps)), "duration_ms": .int((b.lastAt - b.firstAt) / 1000)]
        if !answered { rage["dead"] = true }
        var fields: JSONObject = ["rage": .object(rage)]
        for (k, v) in fieldsOf(b.hit) { fields[k] = v }
        fields["x"] = .double(coordinate(b.firstX))
        fields["y"] = .double(coordinate(b.firstY))
        ctx?.emit("rage_click", fields, viewOf: b.view?.id)
    }

    // Dead.

    private func dead(_ p: FrictionPress, _ at: Int64, _ r: FrictionRules) {
        guard let ctx = ctx, let t = p.target, FrictionTapsPlugin.deadRoles.contains(t.role) else { return }
        if let prev = lastControl, same(prev, p.control), at - lastControlAt < FrictionTapsPlugin.debounceMicros {
            return
        }
        lastControl = p.control
        lastControlAt = at
        let c = Candidate(p.x, p.y, at, fieldsOf(t), p.input, ctx.currentView, p.fingerprint)
        if t.disabled {
            emitDead(c, "disabled", r)
            return
        }
        if p.fingerprint == nil { return }
        candidates.append(c)
        c.stop = watch { [weak self, weak c] answeredAt in
            guard let self = self, let c = c else { return }
            self.answeredAt(c, answeredAt)
        }
        c.timer = ctx.scheduler.schedule(Int64(r.deadWaitMs) * 1000) { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            self.waited(c)
        }
    }

    private func same(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
        guard let a = a, let b = b else { return false }
        if let x = a as? RouteRef, let y = b as? RouteRef { return x.same(y) }
        return a === b
    }

    private func watching(_ c: Candidate) -> Bool { candidates.contains { $0 === c } }

    private func waited(_ c: Candidate) {
        guard let ctx = ctx, let r = rules, watching(c) else { return }
        if ctx.elapsedMicros - c.at > Int64(r.deadWaitMs + FrictionTapsPlugin.blockedMs) * 1000 {
            drop(c)
            return
        }
        // A fingerprint that changed by the wait was answered within it, or cannot say when.
        ctx.fingerprint { [weak self] print in
            guard let self = self, self.watching(c) else { return }
            if print == nil || print != c.fingerprint {
                self.drop(c)
                return
            }
            c.overdue = true
            self.schedule(c, r)
        }
    }

    private func schedule(_ c: Candidate, _ r: FrictionRules) {
        guard let ctx = ctx else { return }
        let late = Int64(r.deadLateMs) * 1000
        let elapsed = ctx.elapsedMicros - c.at
        let recheck = FrictionTapsPlugin.recheckMicros
        let next = elapsed + recheck < late ? recheck : late - elapsed
        c.timer = ctx.scheduler.schedule(max(0, next)) { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            self.check(c)
        }
    }

    private func check(_ c: Candidate) {
        guard let ctx = ctx, let r = rules, watching(c) else { return }
        let now = ctx.elapsedMicros
        ctx.fingerprint { [weak self] print in
            guard let self = self, self.watching(c) else { return }
            if print == nil {
                self.drop(c)
            } else if print != c.fingerprint {
                self.answeredAt(c, now)
            } else if now - c.at >= Int64(r.deadLateMs) * 1000 && self.inactiveAt == nil {
                // Nothing answered yet, unless the app went inactive, which coming back says.
                self.emitDead(c, "none", r)
            } else {
                self.schedule(c, r)
            }
        }
    }

    private func answeredAt(_ c: Candidate, _ at: Int64) {
        guard let r = rules, watching(c) else { return }
        let after = at - c.at
        // Answered within the wait, or past it before its own timer had fired, which is a queue too busy to say.
        if after <= Int64(r.deadWaitMs) * 1000 || !c.overdue {
            drop(c)
            return
        }
        emitDead(c, "late", r, lateMicros: after)
    }

    private func emitDead(_ c: Candidate, _ outcome: String, _ r: FrictionRules, lateMicros: Int64? = nil) {
        drop(c)
        if deadView >= r.deadPerView || deadPage >= r.deadPerPage { return }
        deadView += 1
        deadPage += 1
        var dead: JSONObject = ["outcome": .string(outcome), "wait_ms": .int(Int64(r.deadWaitMs))]
        if let late = lateMicros { dead["late_ms"] = .int(late / 1000) }
        var fields: JSONObject = ["dead": .object(dead)]
        for (k, v) in c.fields { fields[k] = v }
        fields["x"] = .double(coordinate(c.x))
        fields["y"] = .double(coordinate(c.y))
        fields["input"] = .string(c.input)
        ctx?.emit("dead_click", fields, viewOf: c.view?.id)
    }

    private func drop(_ c: Candidate) {
        candidates.removeAll { $0 === c }
        c.stop()
        c.timer?.cancel()
        c.timer = nil
    }

    /// The app is being hidden: the burst ends, and a dead tap past its wait was left, while one inside it cannot be
    /// told from one that would have been answered.
    private func hide() {
        inactiveAt = nil
        windowAway = false
        endBurst(Print(value: hidePrint))
        hidePrint = nil
        let r = rules
        for c in candidates {
            if c.overdue, let r = r { emitDead(c, "left", r) } else { drop(c) }
        }
    }

    // What answers a tap.

    private func watch(_ answered: @escaping (Int64) -> Void) -> () -> Void {
        let id = nextWatcher
        nextWatcher += 1
        watchers.append((id, answered))
        return { [weak self] in self?.watchers.removeAll { $0.id == id } }
    }

    private func answer(_ at: Int64? = nil) {
        if watchers.isEmpty { return }
        let now = at ?? ctx?.elapsedMicros ?? 0
        for w in watchers { w.f(now) }
    }
}
