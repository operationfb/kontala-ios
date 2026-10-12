#if os(iOS)
    import Foundation
    import KontalaCore
    import ObjectiveC
    import UIKit
    import WebKit

    /// What the tap reader tells: the core, through its queue, or a test's record.
    protocol TapSignals: AnyObject {
        func tapped(_ press: Press)
    }

    final class CoreTapSignals: TapSignals {
        private let running: Kontala.Running

        init(_ running: Kontala.Running) {
            self.running = running
        }

        func tapped(_ press: Press) { running.post { $0.tapped(press) } }
    }

    /// A touch as the reader reads it: UIKit's, or a test's.
    struct TouchSample {
        let window: UIWindow
        /// The view UIKit gave the touch to at its start.
        let view: UIView?
        /// Where, in the window's points.
        let point: CGPoint
        /// When, in seconds of the system's uptime, the clock UIKit stamps its events with.
        let time: TimeInterval
        var input = "touch"
        /// Not a pointer's other button, which opens a menu and taps nothing.
        var primary = true
    }

    /// Taps, pointer clicks and keyboard activations in the app's windows, the Android SDK's window callbacks: one hook
    /// on `UIApplication.sendEvent`, which every touch and key passes through before any view or recognizer sees it,
    /// reads each event and hands it on unchanged.
    ///
    /// A press is resolved at its start, while what the visitor pressed is still on show (a control's own action runs
    /// at the end, and may clear a form or open the next screen), and sent at its end where UIKit would have tapped:
    /// the touch stayed on the control, within a scroller's slop where one is around it, and a control that takes a
    /// long press was let go of before it took one. A second finger cancels it.
    ///
    /// From contract 2, a field's form sent from the keyboard is a `submit` row, the Flutter SDK's, read two ways,
    /// since UIKit tells no one else of a field's return key: a hardware Enter in a one-line field that did not move
    /// on to the next field; and a field ending its editing with no other field taking over, and no touch, key or
    /// navigation at the same moment, as an app that handles its keyboard's key and lets go of the field does. A
    /// submit the app handles while the field keeps editing is seen by neither, so these rows are a lower bound.
    ///
    /// Everything here runs on the main thread, and what it reads it posts to the core as a [Press].
    final class TapReader {
        /// The reader the event hook reports to, on the main thread, let go of only once the write is over, as
        /// `ScreenWatcher.current` is.
        static var current: TapReader? {
            get { installed }
            set {
                let old = installed
                installed = newValue
                withExtendedLifetime(old) {}
            }
        }

        private static var installed: TapReader?

        /// How close to a touch, a key or a navigation a field's end of editing is theirs, in seconds.
        static let sameMoment: TimeInterval = 0.3
        /// How far a press may move where a scroller is around it, as a scroll view's pan starts, or on a view a tap
        /// recognizer reads, as a tap fails.
        static let slop: CGFloat = 10
        /// How far outside a control a press may be let go of and still be the control's, as UIKit tracks a touch up
        /// inside one.
        static let controlTolerance: CGFloat = 70

        let signals: TapSignals
        private let switches: Switches
        private let captureText: Bool
        /// When a navigation last began, in uptime seconds, as the screen watcher saw it.
        private let navigationAt: () -> TimeInterval
        /// Whether the app is active, in front.
        private let active: () -> Bool
        /// The focused view of the keyboard's focus system, where there is one.
        private let focused: () -> UIView?

        private var down: Down?
        private weak var touch: UITouch?
        private var key: Down?
        private var enter: Enter?
        private var lastInput: TimeInterval = -.greatestFiniteMagnitude
        private weak var editing: UIView?
        private var observers: [NSObjectProtocol] = []

        init(
            signals: TapSignals, switches: Switches, captureText: Bool,
            navigationAt: @escaping () -> TimeInterval, active: @escaping () -> Bool,
            focused: @escaping () -> UIView? = TapReader.focusedView
        ) {
            self.signals = signals
            self.switches = switches
            self.captureText = captureText
            self.navigationAt = navigationAt
            self.active = active
            self.focused = focused
        }

        /// A press, read at its start: what it acted on, who it names and what it sends, and where UIKit would tap it.
        private struct Down {
            let target: TapTarget
            let control: AnyObject
            let at: TimeInterval
            let input: String
            let namedUser: String?
            let namedOrg: String?
            let submits: JSONObject
            /// A key's HID usage, where a key made the press.
            var code: Int?
            var point: CGPoint?
            /// Where the press may end and still be the control's, in the window.
            var bounds: CGRect?
            /// Whether the press must stay within the slop of where it started.
            var strict = false
            var longPress: TimeInterval?

            func within(_ p: CGPoint) -> Bool {
                guard let b = bounds, let start = point else { return true }
                if !b.contains(p) { return false }
                if !strict { return true }
                let dx = p.x - start.x
                let dy = p.y - start.y
                return dx * dx + dy * dy <= TapReader.slop * TapReader.slop
            }

            func press() -> Press {
                Press(
                    target, control: control, input: input, x: point.map { Double($0.x) },
                    y: point.map { Double($0.y) }, namedUser: namedUser, namedOrg: namedOrg, submits: submits)
            }
        }

        /// A field's Enter, sent at the key's end unless the next field took over.
        private struct Enter {
            let code: Int
            let press: Press
            weak var field: UIView?
        }

        /// Who a press names and, from contract 2, what a submit button sends.
        private struct Read {
            var user: String?
            var org: String?
            var submits = JSONObject()
        }

        // Fields' editing, from UIKit's notifications.

        func observe() {
            let center = NotificationCenter.default
            func on(_ name: Notification.Name, _ f: @escaping (UIView) -> Void) {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { note in
                        if let v = note.object as? UIView { f(v) }
                    })
            }
            on(UITextField.textDidBeginEditingNotification) { [weak self] in self?.fieldBegan($0) }
            on(UITextView.textDidBeginEditingNotification) { [weak self] in self?.fieldBegan($0) }
            on(UITextField.textDidEndEditingNotification) { [weak self] in self?.fieldEnded($0) }
            on(UITextView.textDidEndEditingNotification) { [weak self] in self?.fieldEnded($0) }
        }

        func stopObserving() {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
        }

        // Events, from the hook.

        func read(_ event: UIEvent) {
            switch event.type {
            case .touches: touches(event)
            case .presses: if let p = event as? UIPressesEvent { presses(p) }
            default: break
            }
        }

        private func touches(_ event: UIEvent) {
            guard let all = event.allTouches, !all.isEmpty else { return }
            for t in all where t.phase == .began || t.phase == .ended {
                if let w = t.window, !Self.keyboard(w) { lastInput = max(lastInput, t.timestamp) }
            }
            if let tracked = touch {
                // A second finger: a pinch or a two-finger gesture, no tap.
                if all.contains(where: { $0 !== tracked && $0.phase == .began }) {
                    cancel()
                    return
                }
                guard let s = sample(tracked, event) else { return }
                switch tracked.phase {
                case .moved, .stationary: moved(s)
                case .ended:
                    touch = nil
                    ended(s)
                case .cancelled: cancel()
                default: break
                }
                return
            }
            guard all.count == 1, let t = all.first, t.phase == .began, let w = t.window, !Self.keyboard(w),
                let s = sample(t, event)
            else { return }
            touch = t
            began(s)
        }

        private func sample(_ t: UITouch, _ event: UIEvent) -> TouchSample? {
            guard let w = t.window else { return nil }
            var s = TouchSample(window: w, view: t.view, point: t.location(in: w), time: t.timestamp)
            if t.type == .pencil { s.input = "pen" }
            if #available(iOS 13.4, *), t.type == .indirectPointer {
                s.input = "mouse"
                // A pointer's other button opens a menu and taps nothing.
                s.primary = !event.buttonMask.contains(.secondary)
            }
            return s
        }

        /// Whether a window is the keyboard's, whose keys are no touch of the app's.
        private static func keyboard(_ w: UIWindow) -> Bool {
            let n = NSStringFromClass(type(of: w))
            return n.contains("Keyboard") || n.contains("TextEffects")
        }

        func began(_ s: TouchSample) {
            lastInput = max(lastInput, s.time)
            down = nil
            guard switches.tapsOn, s.primary, let view = s.view else { return }
            let chain = TapResolver.chain(to: view)
            guard let r = TapResolver.resolve(chain, at: s.point, captureText: captureText).target, !r.target.disabled
            else { return }
            let control = r.control
            let bounds = control.convert(control.bounds, to: nil)
            let scrolls = (0..<r.index).contains { i in
                guard let sv = r.chain[i] as? UIScrollView, !(sv is UITextView) else { return false }
                return sv.isScrollEnabled
            }
            let strict = scrolls || !(control is UIControl)
            let tolerance = strict ? Self.slop : Self.controlTolerance
            let read = read(r)
            down = Down(
                target: r.target, control: RouteRef(control), at: s.time, input: s.input, namedUser: read.user,
                namedOrg: read.org, submits: read.submits, point: s.point,
                bounds: bounds.insetBy(dx: -tolerance, dy: -tolerance), strict: strict,
                longPress: TapResolver.longPress(control))
        }

        func moved(_ s: TouchSample) {
            if let d = down, !d.within(s.point) { down = nil }
        }

        func ended(_ s: TouchSample) {
            lastInput = max(lastInput, s.time)
            guard let d = down else { return }
            down = nil
            if !d.within(s.point) { return }
            // A control that takes a long press took one, and no tap.
            if let hold = d.longPress, s.time - d.at >= hold { return }
            signals.tapped(d.press())
        }

        func cancel() {
            down = nil
            touch = nil
        }

        /// Who a press names, a login's user and organisation, and from contract 2 what a submit button sends: the
        /// form it belongs to, by kind and value, and the term of the search box beside it; read at the press, since
        /// its own action may clear the form before its end. The Flutter SDK's `loginOf` and `_formOf`.
        private func read(_ r: ResolvedTarget) -> Read {
            let t = r.target
            if t.isField || t.isChoice { return Read() }
            let scope = TapResolver.formScope(r.chain, r.index)
            let declared = t.declared == .login || t.declared == .signUp
            let login = t.masked ? nil : scope.flatMap { Forms.loginIn(TapResolver.fieldsIn($0), declared: declared) }
            if switches.contract < 2 { return Read(user: login?.user, org: login?.org) }
            var out = JSONObject()
            let button = t.role == "button"
            if let s = scope, button, !TapResolver.fieldsOwnControl(r.chain, r.index, s) {
                let kinds = Forms.fieldKinds(TapResolver.fieldsIn(s))
                let values = t.masked ? JSONObject() : Forms.values(TapResolver.entriesIn(s))
                var form = JSONObject()
                if !kinds.isEmpty { form["fields"] = .array(kinds.map { .string($0) }) }
                if !values.isEmpty { form["values"] = .object(values) }
                out["trigger"] = "click"
                out["form"] = .object(form)
            }
            if !t.masked && (button || t.declared == .search), let term = TapResolver.searchTerm(r.chain, r.index) {
                out["search"] = .string(term)
            }
            return Read(user: login?.user, org: login?.org, submits: out)
        }

        // Keys.

        private func presses(_ event: UIPressesEvent) {
            guard #available(iOS 13.4, *) else { return }
            for p in event.allPresses {
                guard let k = p.key else { continue }
                switch p.phase {
                case .began:
                    lastInput = max(lastInput, p.timestamp)
                    keyDown(k.keyCode.rawValue, plain: k.modifierFlags.subtracting([.numericPad]).isEmpty)
                case .ended:
                    lastInput = max(lastInput, p.timestamp)
                    keyUp(k.keyCode.rawValue)
                default: break
                }
            }
        }

        /// The keys a focused control acts on, by their HID usage: Return, the keypad's Enter and Space.
        static let returnKey = 0x28
        static let keypadEnter = 0x58
        static let space = 0x2C

        private static func activates(_ code: Int) -> Bool {
            code == returnKey || code == keypadEnter || code == space
        }

        func keyDown(_ code: Int, plain: Bool = true) {
            guard Self.activates(code) else { return }
            key = nil
            enter = nil
            guard switches.tapsOn else { return }
            let isEnter = code == Self.returnKey || code == Self.keypadEnter
            if let field = editing, field.window != nil {
                // A field's Enter is its form's submit, from contract 2.
                if isEnter && plain && switches.contract >= 2 && TapResolver.submits(field), let press = submitOf(field)
                {
                    enter = Enter(code: code, press: press, field: field)
                }
                return
            }
            guard let view = focused() else { return }
            let chain = TapResolver.chain(to: view)
            guard let r = TapResolver.resolve(chain, at: centre(view), captureText: captureText).target,
                !r.target.disabled, !r.target.isField
            else { return }
            let read = read(r)
            key = Down(
                target: r.target, control: RouteRef(r.control), at: 0, input: "keyboard", namedUser: read.user,
                namedOrg: read.org, submits: read.submits, code: code)
        }

        func keyUp(_ code: Int) {
            if let k = key, k.code == code {
                key = nil
                signals.tapped(k.press())
            }
            if let e = enter, e.code == code {
                enter = nil
                // Enter moved on to the next field, which a form with a field after this one does.
                if let now = editing, now !== e.field, TapResolver.isField(now) { return }
                signals.tapped(e.press)
            }
        }

        private func centre(_ v: UIView) -> CGPoint {
            v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        }

        /// The view the keyboard's focus system has focused, on an iPad with a keyboard, where there is one.
        static func focusedView() -> UIView? {
            guard #available(iOS 15, *), let w = ScreenWatcher.keyWindow() else { return nil }
            return UIFocusSystem.focusSystem(for: w)?.focusedItem as? UIView
        }

        // Fields.

        func fieldBegan(_ v: UIView) {
            editing = v
        }

        /// A field ended its editing with no other field taking over and no touch, key or navigation at the same
        /// moment: the app handled the keyboard's Search, Done, Go or Send and let go of the field. Read at once,
        /// while the field holds what was sent, and sent a moment later unless another field took over or the field
        /// went with its screen.
        func fieldEnded(_ field: UIView) {
            if editing === field { editing = nil }
            guard switches.tapsOn, switches.contract >= 2 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastInput <= Self.sameMoment || now - navigationAt() <= Self.sameMoment { return }
            guard active(), TapResolver.submits(field), let press = submitOf(field) else { return }
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self = self, let f = field, f.window != nil else { return }
                if let e = self.editing, e !== f, TapResolver.isField(e) { return }
                self.signals.tapped(press)
            }
        }

        /// A field's form sent from the keyboard, as a `submit` row naming the field, the Flutter SDK's `_submit`: a
        /// search box's, with its term, or a login's, naming who logs in. UIKit has no form of its own, so none sends
        /// its values, as a field the web finds in no form sends none.
        private func submitOf(_ field: UIView) -> Press? {
            let chain = TapResolver.chain(to: field)
            guard let r = TapResolver.resolve(chain, at: centre(field), captureText: false).target, r.field != nil
            else { return nil }
            let t = r.target
            // A form's container is above the field's own search bar.
            let outer = TapResolver.fieldOuter(r.chain, r.index)
            let scope = TapResolver.formScope(r.chain, outer)
            let login = t.masked ? nil : scope.flatMap { Forms.loginIn(TapResolver.fieldsIn($0)) }
            let search = t.role == "searchbox"
            if !search && login == nil { return nil }
            var fields: JSONObject = ["trigger": "submit"]
            if !t.masked {
                let term =
                    search
                    ? Forms.term(TapResolver.fieldInfo(field, r.chain)) : TapResolver.searchTerm(r.chain, outer)
                if let term = term { fields["search"] = .string(term) }
            }
            return Press(
                t, control: RouteRef(field), input: "keyboard", namedUser: login?.user, namedOrg: login?.org,
                submits: fields)
        }
    }

    /// `UIApplication.sendEvent`, swizzled once to show the tap reader every event before UIKit delivers it, and
    /// changing nothing of the delivery.
    enum TapHooks {
        static let installed: Void = {
            guard let a = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
                let b = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.kontalaSendEvent(_:)))
            else { return }
            method_exchangeImplementations(a, b)
        }()
    }

    extension UIApplication {
        // Calls what it replaced, which after the exchange is its own selector; `dynamic` for the reason the view
        // controllers' hooks are.
        @objc(kontala_sendEvent:) fileprivate dynamic func kontalaSendEvent(_ event: UIEvent) {
            TapReader.current?.read(event)
            kontalaSendEvent(event)
        }
    }
#endif
