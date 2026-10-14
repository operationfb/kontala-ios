#if os(iOS)
    import Foundation
    import KontalaCore
    import QuartzCore
    import UIKit

    /// Speed's side of the app's windows, on the main thread, the Android SDK's `SpeedWatcher`: each screen numbered as
    /// it is shown, and what is measured of it told to the core as a `SpeedSignal` naming that number, all within one
    /// clock, the system's uptime, which a touch's time, a display link's and the screen watcher's share.
    /// - **A screen's first frame:** the frame after its navigation's first sign, timed from that sign, and a cold
    ///   start's first screen from the process's start, where it was shown within a minute of it. A launch the system
    ///   prewarmed, or whose app went to the background before its first screen, has none, as Sentry times one.
    /// - **Its ready frame:** the frame after the app calls `Kontala.screenReady()`, timed the same way.
    /// - **A tap:** from its end, as UIKit stamped it, to the first frame after its actions ran, which UIKit runs as it
    ///   delivers the end.
    /// - **Its frames:** every frame a display link was called for while it was on show and the app active, those
    ///   that came later than the display's budget allows, and those over 700 ms, as frozen frames are counted. The
    ///   frames from its navigation's first frame on are its own, the transition's included.
    ///
    /// A screen is numbered when its name changes: a view controller loading its view inside the screen on show, as a
    /// child or a cell's does, begins no screen, and nor does the screen on show read again.
    final class SpeedWatcher {
        /// How long before a navigation its last tap may be, to have caused it.
        static let invWindow: TimeInterval = 3

        /// The longest a cold start's first screen may take to be timed.
        static let launchLimit: TimeInterval = 60

        /// How long a frame may take before it is frozen.
        static let frozenFrame: TimeInterval = 0.7

        /// How many screens that ended are kept for what is still to come of them.
        static let endedKept = 4

        var signals: MeasureSignals?

        private let switches: Switches
        private let processStart: TimeInterval?
        private let countsFrames: Bool
        private let now: () -> TimeInterval
        private let nextFrame: (@escaping () -> Void) -> Void

        private final class Screen {
            let number: Int
            let launch: Bool
            let start: TimeInterval?
            var frames: Int64 = 0
            var slow: Int64 = 0
            var frozen: Int64 = 0
            var told: Int64 = -1
            var pending = 0
            var readyAsked = false
            var settled = false
            /// Whether a frame came after it ended, after which none of its frames is still to come.
            var framedAfter = false

            init(_ number: Int, _ launch: Bool, _ start: TimeInterval?) {
                self.number = number
                self.launch = launch
                self.start = start
            }
        }

        private var number = 0
        private var current: Screen?
        private var ended: [Screen] = []
        private var launched = false

        /// Whether the app went to the background before its first screen, which then shows when the visitor comes
        /// back, rather than as the process starts.
        private var hiddenBeforeLaunch = false

        /// The last tap's end, for the screen it opened.
        private var lastTap: TimeInterval?

        /// The frames of the screen on show as a navigation's first frame was drawn: the next screen's are counted
        /// from then.
        private var atNavigation: (frames: Int64, slow: Int64, frozen: Int64)?

        private var link: CADisplayLink?
        private var lastFrame: CFTimeInterval?
        private var active = true
        private var observers: [NSObjectProtocol] = []

        /// [processStart] is when the process started, in seconds of the system's uptime, or nil where a launch is not
        /// timed; [countsFrames] whether a display link counts frames, which a test leaves to `frame`.
        init(
            switches: Switches, processStart: TimeInterval?, countsFrames: Bool = true,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            nextFrame: @escaping (@escaping () -> Void) -> Void = NextFrame.after
        ) {
            self.switches = switches
            self.processStart = processStart
            self.countsFrames = countsFrames
            self.now = now
            self.nextFrame = nextFrame
        }

        private var on: Bool { switches.frictionRules != nil }

        /// When the process started, in seconds of the system's uptime, from the kernel's record of it; nil where the
        /// system prewarmed it, whose first screen comes when the visitor opens the app rather than when the process
        /// started. A scene's app is in the background as it finishes launching, whatever launched it, so that says
        /// nothing here.
        static func processStartUptime() -> TimeInterval? {
            if ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" { return nil }
            guard let wall = Facts.processStartMs() else { return nil }
            let ago = Date().timeIntervalSince1970 - Double(wall) / 1000
            return ago >= 0 ? ProcessInfo.processInfo.systemUptime - ago : nil
        }

        /// A navigation's first frame was drawn, before its screen is known: what is drawn from now is the next
        /// screen's.
        func navigationFramed() {
            guard let s = current else { return }
            atNavigation = (s.frames, s.slow, s.frozen)
        }

        /// A navigation settled, on another screen or on the same: the screen on show keeps what it drew.
        func navigationSettled() {
            atNavigation = nil
        }

        /// A screen is about to be told, its navigation having begun at [start] and drawn its first frame at
        /// [framedAt], in seconds of the system's uptime: it is numbered, and its first frame timed.
        func shown(start: TimeInterval?, framedAt: TimeInterval) {
            let launch = !launched
            launched = true
            number += 1
            let s = Screen(number, launch, launch ? (hiddenBeforeLaunch ? nil : processStart) : start)
            if let old = current {
                if let n = atNavigation {
                    s.frames = old.frames - n.frames
                    s.slow = old.slow - n.slow
                    s.frozen = old.frozen - n.frozen
                    old.frames = n.frames
                    old.slow = n.slow
                    old.frozen = n.frozen
                }
                tellFrames(old)
                ended.insert(old, at: 0)
                if ended.count > SpeedWatcher.endedKept { ended.removeLast() }
            }
            atNavigation = nil
            current = s
            guard let signals = signals else { return }
            signals.screenNumbered(s.number)
            guard on else { return }
            startFrames()
            var inv: Int64?
            if !launch, let st = start, let tap = lastTap, st - tap >= 0, st - tap <= SpeedWatcher.invWindow {
                inv = SpeedWatcher.ms(framedAt - tap)
            }
            signals.measured(.firstFrame(screen: s.number, launch: launch, fcpMs: since(s, framedAt), invMs: inv))
        }

        /// How soon after a change a display link's call is for the frame already begun, which the change is too late
        /// for: half a frame at 60 Hz.
        static let sameFrame: TimeInterval = 0.008

        /// Runs [f] at the first frame drawn after a change made [since], with when that is: UIKit delivers a touch on
        /// the display's beat, and the display link's call for the frame already begun then comes straight after it,
        /// before anything the touch changed is committed; the change shows in the frame after.
        private func afterFrame(_ since: TimeInterval, _ f: @escaping (TimeInterval) -> Void) {
            nextFrame { [weak self] in
                guard let self = self else { return }
                if self.now() - since >= SpeedWatcher.sameFrame { return f(self.now()) }
                self.nextFrame { [weak self] in
                    guard let self = self else { return }
                    f(self.now())
                }
            }
        }

        /// The app said its screen is fully displayed: the frame after it is its time to full display.
        func ready() {
            guard on, let s = current, !s.readyAsked else { return }
            s.readyAsked = true
            afterFrame(now()) { [weak self] end in
                guard let self = self, let lcp = self.since(s, end) else { return }
                self.signals?.measured(.ready(screen: s.number, lcpMs: lcp))
            }
        }

        /// A tap ended at [at], in seconds of the system's uptime, and UIKit delivered it: its actions have run, so
        /// the next frame drawn is the one its answer shows in.
        func tapped(at: TimeInterval, target: TapTarget?) {
            lastTap = at
            guard on, let s = current else { return }
            s.pending += 1
            signals?.measured(.tapped(screen: s.number))
            let delivered = now()
            afterFrame(delivered) { [weak self] end in
                guard let self = self else { return }
                s.pending -= 1
                let latency = SpeedWatcher.ms(end - at)
                if latency >= 0 {
                    self.signals?.measured(
                        .interaction(
                            screen: s.number, latencyMs: latency,
                            processingMs: max(0, SpeedWatcher.ms(delivered - at)),
                            presentationMs: max(0, SpeedWatcher.ms(end - max(delivered, at))), role: target?.role,
                            path: target?.path))
                }
                self.settle()
            }
        }

        /// The app is about to be said hidden: the frames of its screen so far.
        func hiding() {
            if let s = current { tellFrames(s) }
        }

        /// A frame the display showed [gap] after the one before, within a [budget] of its own: counted for the
        /// screen on show.
        func frame(gap: TimeInterval, budget: TimeInterval) {
            guard on, let s = current else { return }
            s.frames += 1
            if gap > max(budget, 1.0 / 240) * 1.5 { s.slow += 1 }
            if gap > SpeedWatcher.frozenFrame { s.frozen += 1 }
            // A frame of a later screen: everything an ended one drew is in.
            for e in ended { e.framedAfter = true }
            settle()
        }

        // The display link, which runs while speed is measured and the app is active.

        func observe() {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    guard let self = self else { return }
                    self.active = true
                    if self.current != nil && self.on { self.startFrames() }
                })
            observers.append(
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    self?.active = false
                    self?.stopFrames()
                })
            observers.append(
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    guard let self = self, !self.launched else { return }
                    self.hiddenBeforeLaunch = true
                })
        }

        func stop() {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            stopFrames()
        }

        private final class Ticker {
            weak var owner: SpeedWatcher?

            init(_ owner: SpeedWatcher) {
                self.owner = owner
            }

            @objc func tick(_ link: CADisplayLink) {
                guard let o = owner else {
                    link.invalidate()
                    return
                }
                o.tick(link)
            }
        }

        private func startFrames() {
            guard countsFrames, active, link == nil else { return }
            let l = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            lastFrame = nil
        }

        private func stopFrames() {
            link?.invalidate()
            link = nil
            lastFrame = nil
        }

        private func tick(_ l: CADisplayLink) {
            guard on else { return stopFrames() }
            let t = l.timestamp
            defer { lastFrame = t }
            guard let previous = lastFrame else { return }
            frame(gap: t - previous, budget: l.targetTimestamp - l.timestamp)
        }

        /// Tells the core every ended screen whose frames and taps are all in: its last frames, and that it settled.
        private func settle() {
            for s in ended where !s.settled && s.pending == 0 && s.framedAfter {
                s.settled = true
                tellFrames(s)
                signals?.measured(.settled(screen: s.number))
            }
        }

        private func tellFrames(_ s: Screen) {
            guard on, s.frames > 0, s.frames != s.told else { return }
            s.told = s.frames
            signals?.measured(.frames(screen: s.number, total: s.frames, slow: s.slow, frozen: s.frozen))
        }

        /// A first or a ready frame's time since its screen began, or nil where it cannot be timed.
        private func since(_ s: Screen, _ at: TimeInterval) -> Int64? {
            guard let start = s.start else { return nil }
            let d = at - start
            if d < 0 || (s.launch && d > SpeedWatcher.launchLimit) { return nil }
            return SpeedWatcher.ms(d)
        }

        private static func ms(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }
    }
#endif
