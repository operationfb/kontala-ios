import Foundation

/// Kontala for a native iOS app: screen views, taps, logins and the app's lifecycle, captured as Kontala's web tag
/// captures a site, and sent to the Events API.
///
/// ```swift
/// @main
/// struct ShopApp: App {
///     init() {
///         Kontala.start(writeKey: "pk_live_...", endpoint: "https://konta.la/v1/events")
///     }
/// }
/// ```
///
/// Every method may be called from any thread, and before `start`: calls made before it are kept and applied, in
/// order, before the first screen is captured, so an app that restores its signed-in session as it starts has its
/// first screen view already identified. Callbacks are answered on the main thread.
public enum Kontala {
    private static let lock = NSLock()
    private static var running: Running?
    private static var initialised = false
    private static var pending: [(Core) -> Void] = []
    private static var pendingConsent: KontalaConsent?
    private static var consentMirror: KontalaConsent?
    private static var optOutMirror: Bool?

    /// What one start of the SDK runs on.
    package final class Running {
        package let core: Core
        package let scheduler: Scheduler
        /// Runs a block on the main thread, where the app's callbacks are answered.
        package let main: (@escaping () -> Void) -> Void
        package let onStop: () -> Void

        /// Where a warning of the app's own calls goes: the debug log, or a debug build's.
        package var warn: (String) -> Void = { _ in }

        package init(
            core: Core, scheduler: Scheduler, main: @escaping (@escaping () -> Void) -> Void,
            onStop: @escaping () -> Void
        ) {
            self.core = core
            self.scheduler = scheduler
            self.main = main
            self.onStop = onStop
        }

        /// Runs [f] on the core's queue.
        package func post(_ f: @escaping (Core) -> Void) {
            let core = self.core
            scheduler.post { f(core) }
        }
    }

    private static func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    /// The SDK started, or nil.
    package static var current: Running? { locked { running } }

    /// Starts the core on what it is given: iOS's in `start(writeKey:endpoint:options:)`, a test's in the suite.
    @discardableResult
    package static func start(
        writeKey: String, endpoint: String, options: KontalaOptions, platform: Platform, scheduler: Scheduler,
        http: Http, clock: Clock, main: @escaping (@escaping () -> Void) -> Void, onStop: @escaping () -> Void
    ) -> Running? {
        let r: Running? = locked {
            if initialised { return nil }
            initialised = true
            let core = Core(
                writeKey: writeKey, endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                options: options, platform: platform, scheduler: scheduler, http: http, clock: clock)
            let started = Running(core: core, scheduler: scheduler, main: main, onStop: onStop)
            running = started
            let calls = pending
            pending.removeAll()
            pendingConsent = nil
            scheduler.post {
                core.start()
                for c in calls { c(core) }
            }
            return started
        }
        if r == nil { platform.log("[kontala] Kontala.start was called more than once; the first call stands") }
        return r
    }

    private static func call(_ f: @escaping (Core) -> Void) {
        let r: Running? = locked {
            if let current = running { return current }
            if !initialised && pending.count < 256 { pending.append(f) }
            return nil
        }
        r?.post(f)
    }

    /// An app's properties, held to what the Events API takes, and why anything of them was left out.
    private static func convert(_ properties: [String: Any]?) -> (JSONObject?, [String]) {
        guard let p = properties else { return (nil, []) }
        var notes: [String] = []
        let o = jsonSafe(p, log: { notes.append($0) })?.object
        return (o, notes)
    }

    /// Who uses the app: its own [user] and [org] ids, stamped on every event from now on, and replaced whole by the
    /// next call, so `identify()` with neither is the logout. Non-empty [traits] are sent once, as an `identify` event
    /// naming them.
    public static func identify(user: String? = nil, org: String? = nil, traits: [String: Any]? = nil) {
        let (t, notes) = convert(traits)
        call { core in
            for n in notes { core.log(n) }
            core.identify(user, org, t)
        }
    }

    /// A logout that also forgets this device: the next event has a new device and session. A plain logout is
    /// `identify()`.
    public static func reset() { call { $0.reset() } }

    /// Stops all capture, sending and storage on this device, across launches, and deletes what is queued and stored;
    /// `optOut(false)` starts again.
    public static func optOut(_ out: Bool) {
        locked { optOutMirror = out }
        call { $0.optOut(out) }
    }

    /// Whether the visitor opted out, as last said in this process.
    public static var isOptedOut: Bool { locked { optOutMirror } ?? false }

    /// The visitor's answer: `.granted` sends everything and stores the ids; `.denied` and `.unknown` store nothing,
    /// send rows the collector redacts, and leave out taps.
    public static func consent(_ state: KontalaConsent) {
        locked {
            consentMirror = state
            if running == nil && !initialised { pendingConsent = state }
        }
        call { $0.consent(state) }
    }

    /// The consent state in force.
    public static var consentState: KontalaConsent {
        locked { consentMirror ?? pendingConsent ?? running?.core.options.consent } ?? .granted
    }

    /// A custom event, the app's counterpart of a data layer push. Its [properties] are data layer data, discovered and
    /// mapped in Kontala.
    public static func track(_ name: String, properties: [String: Any]? = nil) {
        let (p, notes) = convert(properties)
        call { core in
            for n in notes { core.log(n) }
            core.track(name, p)
        }
    }

    /// Properties every screen view carries from now on, as its data layer.
    public static func register(_ properties: [String: Any]) {
        let (p, notes) = convert(properties)
        call { core in
            for n in notes { core.log(n) }
            core.register(p ?? JSONObject())
        }
    }

    public static func unregister(_ key: String) { call { $0.unregister(key) } }

    /// The page type of the screen on show, which always wins over anything Kontala works out. Declared during a
    /// navigation, it is the next screen's.
    public static func pageType(_ type: KontalaPageType) { call { $0.pageType(type) } }

    /// Names the screen on show where no view controller does, a SwiftUI screen among them.
    public static func screen(_ name: String, pageType: KontalaPageType? = nil, properties: [String: Any]? = nil) {
        let (p, notes) = convert(properties)
        call { core in
            for n in notes { core.log(n) }
            core.screen(name, pageType, p)
        }
    }

    /// Properties the screen on show carries as its data layer.
    public static func screenData(_ properties: [String: Any]) {
        let (p, notes) = convert(properties)
        call { core in
            for n in notes { core.log(n) }
            core.screenData(p ?? JSONObject())
        }
    }

    /// A link that opened the app, or that it was sent while running, from `scene(_:openURLContexts:)`, the scene's
    /// `connectionOptions.urlContexts`, `application(_:open:options:)` or SwiftUI's `.onOpenURL`: the screen it opens
    /// is a `link`, with the link's query, so its campaign is on the visit. One that opened the app names its launch
    /// screen while that is unsent: iOS gives a cold start's link only after the first frame, and the launch's screen
    /// view waits three seconds for it.
    public static func handle(url: URL) {
        let link = url.absoluteString
        call { $0.hub.linkPushed(link) }
    }

    /// Marks the screen on show as fully displayed: its content loaded and drawn. Kontala times the screen to the frame
    /// after it as its time to full display, the web's LCP, where the property captures friction.
    public static func screenReady() { call { $0.screenReady() } }

    /// Shows iOS's tracking prompt, App Tracking Transparency's, and answers the visitor's choice, `authorized`,
    /// `denied`, `restricted` or `not_determined`, on the main thread: the advertising id rides on consented events
    /// from then on where the visitor authorised it. Before `start`, it answers nil.
    public static func requestTrackingAuthorization(_ callback: @escaping (String?) -> Void) {
        guard let r = current else {
            callback(nil)
            return
        }
        r.post { core in core.requestTrackingAuthorization { status in r.main { callback(status) } } }
    }

    /// [callback] is answered on the main thread once the websites the app shows in a web view have its ids, written
    /// into the cookie store its web views share for the Kontala tag on their pages to read, so a page and the app are
    /// one visitor and one visit. Show a web view at launch from it; one shown later needs nothing. It never waits
    /// past half a second, and with no websites, or no consent to write to the device, it answers at once.
    public static func webViewsReady(_ callback: @escaping () -> Void) {
        guard let r = current else {
            callback()
            return
        }
        r.post { core in core.whenWebReady { r.main(callback) } }
    }

    /// Sends everything queued now; [callback], if any, is answered on the main thread once nothing is in flight.
    public static func flush(_ callback: (() -> Void)? = nil) {
        guard let r = current else {
            callback?()
            return
        }
        r.post { core in
            core.flush {
                if let cb = callback { r.main(cb) }
            }
        }
    }

    /// Removes every hook and stops sending. What is queued stays on disk and is sent by the next start.
    public static func stop() {
        let r: Running? = locked {
            guard let current = running else { return nil }
            running = nil
            initialised = false
            return current
        }
        guard let stopping = r else { return }
        stopping.post { core in
            core.stop()
            stopping.onStop()
        }
    }

    /// Forgets everything static, for tests.
    package static func debugReset() {
        stop()
        locked {
            pending.removeAll()
            pendingConsent = nil
            initialised = false
            running = nil
            consentMirror = nil
            optOutMirror = nil
        }
    }
}
