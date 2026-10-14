#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit

    /// Friction's side of the app's windows, on the main thread, the Android SDK's `FrictionReader`: each tap, on a
    /// control or not, read at its start and told at its end as a `FrictionPress`, with what the app showed as it
    /// began; and what answers a tap that the core cannot see: a field beginning its editing other than by the press
    /// itself, the keyboard showing or going, the screen's scroll view moving, and another window taking the key. The
    /// rules and their timers are the core's (`FrictionTapsPlugin`), which asks for a fingerprint of what the app shows
    /// when nothing cheaper says (`fingerprint`).
    final class FrictionReader {
        /// How long a press may be held and still be a tap, as UIKit's long press waits by default.
        static let longPress: TimeInterval = 0.5

        /// How often a scroll is told as an answer while it goes on, in seconds.
        static let scrollEvery: TimeInterval = 0.1

        var signals: MeasureSignals?

        /// Told of every tap, for the speed of its screen.
        var speed: SpeedWatcher?

        private let switches: Switches
        private let debug: Bool
        private let windows: () -> [UIWindow]
        private let now: () -> TimeInterval

        /// A press as friction read it at its start, until its end.
        private struct Down {
            let hit: TapTarget
            let target: TapTarget?
            let control: AnyObject?
            let excluded: Bool
            let point: CGPoint
            let at: TimeInterval
            let input: String
            let fingerprint: Int64?
        }

        /// A tap that ended, as the speed of its screen counts it: when, and the control it was on.
        struct Tap {
            let at: TimeInterval
            let target: TapTarget?
        }

        private var press: Down?

        /// The press still down, whose action may throw before its end, and the last one finished: read on the
        /// thread that crashes.
        private let taps = Shared<(pressing: LastTap?, finished: LastTap?)>((nil, nil))

        /// Whether a field beginning its editing now is the press's own, which is no answer.
        private var quiet = false

        /// The last tap's end and where it began: whether a press continues a burst.
        private var lastUp = -TimeInterval.greatestFiniteMagnitude
        private var lastX = 0.0
        private var lastY = 0.0

        private var lastScroll = -TimeInterval.greatestFiniteMagnitude
        private var observers: [NSObjectProtocol] = []

        init(
            switches: Switches, debug: Bool, windows: @escaping () -> [UIWindow],
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.switches = switches
            self.debug = debug
            self.windows = windows
            self.now = now
        }

        /// The last tap, for an error moments after it: the press still down, else the last one finished.
        var lastTap: LastTap? {
            let t = taps.value
            return t.pressing ?? t.finished
        }

        private var on: Bool { switches.frictionRules != nil }

        /// A touch began: what it is on, and what the app shows, read now, while they are as the visitor saw them.
        func down(_ p: Pointer) {
            press = nil
            taps.value.pressing = nil
            guard let rules = switches.frictionRules else { return }
            let s = p.sample
            if s.input == "mouse" && !s.primary { return }
            let hit: TapTarget
            let target: TapTarget?
            let control: AnyObject?
            switch p.resolution {
            case .ignored:
                return
            case .target(let r):
                hit = r.target
                target = r.target
                control = RouteRef(r.control)
            case .none:
                if let d = p.disabled {
                    // A control the app disabled, which UIKit gave the touch past: a dead tap at once.
                    hit = d.target
                    target = d.target
                    control = RouteRef(d.control)
                } else {
                    guard let h = TapResolver.describeHit(p.chain, at: s.point) else { return }
                    hit = h
                    target = nil
                    control = nil
                }
            }
            let excluded = TapResolver.rageExcluded(p.chain)
            let x = Double(s.point.x)
            let y = Double(s.point.y)
            let candidate = target.map { !$0.disabled && FrictionTapsPlugin.deadRoles.contains($0.role) } ?? false
            // A fingerprint for a dead tap's candidate, and for every tap that does not continue a burst, whose own
            // fingerprint is what the app shows as the burst before it ends.
            let continues =
                !excluded && s.time - lastUp <= Double(rules.rageWindowMs) / 1000
                && abs(x - lastX) + abs(y - lastY) <= Double(rules.rageRadiusPx)
            let print = candidate || !continues ? fingerprint() : nil
            quiet = true
            taps.value.pressing = LastTap(at: s.time, fields: fieldsOf(hit))
            press = Down(
                hit: hit, target: target, control: control, excluded: excluded, point: s.point, at: s.time,
                input: s.input, fingerprint: print)
        }

        /// A touch moved: past the slop, the press is a drag.
        func moved(_ s: TouchSample) {
            guard let d = press else { return }
            let dx = s.point.x - d.point.x
            let dy = s.point.y - d.point.y
            if dx * dx + dy * dy > TapReader.slop * TapReader.slop { cancel() }
        }

        /// A second finger, or the gesture taken away: no tap.
        func cancel() {
            press = nil
            taps.value.pressing = nil
        }

        /// The touch ended, before UIKit delivers it: a tap, unless it was held into a long press.
        func up(_ s: TouchSample) -> Tap? {
            guard let d = press else { return nil }
            press = nil
            if s.time - d.at > FrictionReader.longPress {
                taps.value.pressing = nil
                return nil
            }
            lastUp = s.time
            lastX = Double(d.point.x)
            lastY = Double(d.point.y)
            taps.value = (nil, LastTap(at: d.at, fields: fieldsOf(d.hit)))
            signals?.pressed(
                FrictionPress(
                    hit: d.hit, target: d.target, control: d.control, excluded: d.excluded, x: Double(d.point.x),
                    y: Double(d.point.y), input: d.input, fingerprint: d.fingerprint))
            return Tap(at: s.time, target: d.target)
        }

        /// UIKit delivered the touch's end: a field its action began editing is still the press's, and is no answer
        /// from the next turn of the main thread on; the tap's actions have run, so its time to the next frame is
        /// measured.
        func dispatched(_ tap: Tap?) {
            DispatchQueue.main.async { [weak self] in self?.quiet = false }
            if let t = tap { speed?.tapped(at: t.at, target: t.target) }
        }

        // What answers a tap, from UIKit's notifications.

        func observe() {
            let center = NotificationCenter.default
            func on(_ name: Notification.Name, _ f: @escaping (Notification) -> Void) {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: f))
            }
            on(UITextField.textDidBeginEditingNotification) { [weak self] _ in self?.fieldBegan() }
            on(UITextView.textDidBeginEditingNotification) { [weak self] _ in self?.fieldBegan() }
            on(UIResponder.keyboardWillShowNotification) { [weak self] _ in self?.keyboardChanged() }
            on(UIResponder.keyboardWillHideNotification) { [weak self] _ in self?.keyboardChanged() }
            on(UIWindow.didBecomeKeyNotification) { [weak self] n in self?.keyChanged(n.object, focused: true) }
            on(UIWindow.didResignKeyNotification) { [weak self] n in self?.keyChanged(n.object, focused: false) }
        }

        func stopObserving() {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
        }

        /// A field began its editing: an answer, unless a press began it.
        func fieldBegan() {
            if on && !quiet { signals?.answered() }
        }

        /// The keyboard is showing or going: an answer.
        func keyboardChanged() {
            if on { signals?.answered() }
        }

        /// The screen's scroll view moved: an answer, told at most every 100 ms, since a scroll goes on for many
        /// frames.
        func scrollChanged() {
            if !on { return }
            let t = now()
            if t - lastScroll < FrictionReader.scrollEvery { return }
            lastScroll = t
            signals?.answered()
        }

        /// A window of the app's became the key window or stopped being it: an alert's, a popup's or the app's own.
        private func keyChanged(_ window: Any?, focused: Bool) {
            guard on, let w = window as? UIWindow, !TapReader.keyboard(w) else { return }
            signals?.windowFocus(focused)
        }

        /// The app is about to be said hidden: what it shows now is what a burst still open ends on.
        func hiding() {
            if on { signals?.hiding(fingerprint()) }
        }

        /// A fingerprint of what the app shows now, every window of it on screen.
        func fingerprint() -> Int64? { Fingerprints.of(windows(), debug: debug) }

        private func fieldsOf(_ t: TapTarget) -> JSONObject {
            var described = t
            described.declared = nil
            return described.toFields()
        }
    }
#endif
