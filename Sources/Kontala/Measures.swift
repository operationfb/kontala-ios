#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit

    /// What the measures' readers tell: the core, through its queue, or a test's record.
    protocol MeasureSignals: AnyObject {
        /// A tap as friction reads it, on a control or not.
        func pressed(_ press: FrictionPress)

        /// Something on show answered whatever was tapped: a field began its editing, the keyboard showed, a scroll.
        func answered()

        /// Another window of the app's took the key from the screen's, or gave it back.
        func windowFocus(_ focused: Bool)

        /// What the app showed as it went to the background, read just before it said so.
        func hiding(_ print: Int64?)

        /// A reading of the screen's scroll view.
        func scrolled(_ reading: Reading)

        /// A swipe read off a finger's touches.
        func swiped(_ swipe: Swipe)

        /// The screen about to be told is numbered [screen], which what is measured of it names.
        func screenNumbered(_ screen: Int)

        /// What was measured of a screen's speed.
        func measured(_ signal: SpeedSignal)
    }

    /// The core as the measures' readers tell it, through its queue.
    final class CoreMeasureSignals: MeasureSignals {
        private let running: Kontala.Running

        init(_ running: Kontala.Running) {
            self.running = running
        }

        func pressed(_ press: FrictionPress) { running.post { $0.pressed(press) } }
        func answered() { running.post { $0.answered() } }
        func windowFocus(_ focused: Bool) { running.post { $0.windowFocus(focused) } }
        func hiding(_ print: Int64?) { running.post { $0.hiding(print) } }
        func scrolled(_ reading: Reading) { running.post { $0.scrolled(reading) } }
        func swiped(_ swipe: Swipe) { running.post { $0.swiped(swipe) } }
        func screenNumbered(_ screen: Int) { running.post { $0.screenNumbered(screen) } }
        func measured(_ signal: SpeedSignal) { running.post { $0.measured(signal) } }
    }

    /// A touch at its start as every reader of it reads it: where, on which views, and what a tap there acts on,
    /// resolved once, when a reader first asks.
    final class Pointer {
        let sample: TouchSample
        /// The views from the window down to the one UIKit gave the touch to.
        let chain: [UIView]
        private let captureText: Bool
        private var resolved: TapResolution?

        init(_ sample: TouchSample, chain: [UIView], captureText: Bool) {
            self.sample = sample
            self.chain = chain
            self.captureText = captureText
        }

        var resolution: TapResolution {
            if let r = resolved { return r }
            let r = TapResolver.resolve(chain, at: sample.point, captureText: captureText)
            resolved = r
            return r
        }

        /// The disabled control under the touch, which UIKit's hit test passes over, where nothing enabled took it.
        var disabled: ResolvedTarget? {
            TapResolver.disabledAt(sample.point, in: sample.window, captureText: captureText)
        }
    }

    /// The last tap, for an error moments after it: when it began, in seconds of the system's uptime, and what it was
    /// on.
    struct LastTap {
        let at: TimeInterval
        let fields: JSONObject
    }

    /// The measures' readers of a running SDK, each where the app's options ask for it, taken away as it stops.
    final class MeasureReaders {
        var friction: FrictionReader?
        var swipes: SwipeReader?
        var scroll: ScrollWatcher?
        var speed: SpeedWatcher?
        var crashes: Crashes?

        /// The app's windows on show, the keyboard's aside, in the order the scene holds them.
        static func windows() -> [UIWindow] {
            guard let scene = ScreenWatcher.keyWindow()?.windowScene else { return [] }
            return scene.windows.filter { !$0.isHidden && !TapReader.keyboard($0) }
        }

        /// Wires the readers [options] ask for to the core [running] is, to the screen watcher, the lifecycle and the
        /// platform, on the main thread. The readers of a hide are told before the core hears of it, in the order
        /// the Android SDK registers them.
        init(
            _ running: Kontala.Running, options: KontalaOptions, watcher: ScreenWatcher, lifecycle: AppLifecycle,
            platform: ApplePlatform
        ) {
            let signals = CoreMeasureSignals(running)
            let switches = running.core.switches
            if options.friction {
                let f = FrictionReader(switches: switches, debug: options.debug, windows: MeasureReaders.windows)
                f.signals = signals
                f.observe()
                lifecycle.beforeHide.append { [weak f] in f?.hiding() }
                platform.fingerprinter = { [weak f] in f?.fingerprint() }
                friction = f
                let visible = lifecycle.visible
                let c = Crashes(
                    context: { [weak core = running.core] in core?.crashContext }, lastTap: { [weak f] in f?.lastTap },
                    visible: { visible.value })
                c.install()
                crashes = c
            }
            if options.scroll {
                let s = SwipeReader(switches: switches)
                s.signals = signals
                swipes = s
                let w = ScrollWatcher(switches: switches)
                w.signals = signals
                w.moved = { [weak f = friction] in f?.scrollChanged() }
                lifecycle.beforeHide.append { [weak w] in w?.hiding() }
                scroll = w
            }
            if options.friction && options.screens {
                let s = SpeedWatcher(switches: switches, processStart: SpeedWatcher.processStartUptime())
                s.signals = signals
                s.observe()
                friction?.speed = s
                lifecycle.beforeHide.append { [weak s] in s?.hiding() }
                platform.readier = { [weak s] in s?.ready() }
                speed = s
            }
            watcher.onFirstFrame = { [weak s = speed] in s?.navigationFramed() }
            watcher.onScreen = { [weak s = speed, weak w = scroll] start, framedAt, vc, renamed in
                if renamed { s?.shown(start: start, framedAt: framedAt) }
                w?.shown(vc)
            }
            watcher.onSettled = { [weak s = speed] in s?.navigationSettled() }
        }

        func stop() {
            crashes?.uninstall()
            friction?.stopObserving()
            speed?.stop()
            scroll?.stop()
        }
    }

    /// A value read on any thread and written on the main thread: what the thread that crashes reads.
    final class Shared<T> {
        private let lock = NSLock()
        private var stored: T

        init(_ value: T) {
            stored = value
        }

        var value: T {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
#endif
