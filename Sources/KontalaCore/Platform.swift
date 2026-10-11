import Foundation

/// What the core needs of the platform it runs on, the Flutter plugin's method channel as direct calls: iOS's in
/// production (the `Kontala` module), a test's fake in the suite. Every call is made on the core's queue; one that
/// waits on another thread answers through its callback, on any thread.
package protocol Platform: Environment {
    /// What the platform says about the app and the device, read once.
    func facts() -> PlatformFacts

    /// Where the app is as the SDK starts: a process launched into the background is hidden, one launched for a
    /// scene is not.
    func initialState() -> AppState

    /// The platform's own ids for the device.
    func deviceIds(_ done: @escaping (DeviceIds?) -> Void)

    /// Shows the platform's tracking prompt where it has one, and answers the visitor's choice.
    func requestTrackingAuthorization(_ done: @escaping (String?) -> Void)

    /// Asks for time to finish a flush once the app is hidden: iOS gives a hidden app none of its own.
    func beginBackgroundTask() -> Any?

    func endBackgroundTask(_ token: Any?)

    /// A fingerprint of what the app shows, read on the main thread, which tells whether a tap was answered where
    /// nothing cheaper says; nil where it cannot be read. Answered on any thread.
    func fingerprint(_ done: @escaping (Int64?) -> Void)

    /// The app said its screen is fully displayed: the platform times the frame after it, as a speed signal.
    func screenReady()

    /// Writes [cookies] into the store every web view of the app shares, and answers once the store has them all, or
    /// false where it has none. Answered on any thread.
    func writeWebCookies(_ cookies: [WebCookie], _ done: @escaping (Bool) -> Void)

    /// Reads the cookies [names] as each of [origins]' pages see them from the store the app's web views share: for
    /// each origin, in order, the raw values of those it has, or nil where nothing answers. Answered on any thread.
    func readWebCookies(_ origins: [WebOrigin], _ names: [String], _ done: @escaping ([[String: String]]?) -> Void)

    /// Whether a web view is on show in a window of the app's, looked for again over the next [frames] frames while
    /// none is, since a screen's web view may be laid out only then. Answered on any thread.
    func webViewShown(_ frames: Int, _ done: @escaping (Bool) -> Void)

    /// Writes one line of the SDK's log.
    func log(_ line: String)

    /// Whether the app is a debug build, whose warnings are logged even without `debug`.
    var debuggable: Bool { get }
}

extension Platform {
    package func beginBackgroundTask() -> Any? { nil }
    package func endBackgroundTask(_ token: Any?) {}
    package func fingerprint(_ done: @escaping (Int64?) -> Void) { done(nil) }
    package func screenReady() {}
    package func writeWebCookies(_ cookies: [WebCookie], _ done: @escaping (Bool) -> Void) { done(false) }
    package func readWebCookies(
        _ origins: [WebOrigin], _ names: [String], _ done: @escaping ([[String: String]]?) -> Void
    ) { done(nil) }
    package func webViewShown(_ frames: Int, _ done: @escaping (Bool) -> Void) { done(false) }
}

/// What the core says it captures, for the main thread, where taps, scrolling and friction are read off the app's
/// views: nothing is read there that the core would drop, and the rules it reads by are the ones the property is
/// served. The core publishes it as what is served and what the API said change; its plugins decide again as each
/// reading arrives.
package final class Switches {
    private let lock = NSLock()
    private let now: () -> Int64

    private var _contract = 1
    private var _taps = false
    private var _scroll: ScrollRules?
    private var _friction: FrictionRules?
    private var _clicksOffUntil: Int64 = 0
    private var _scrollOffUntil: Int64 = 0
    private var _frictionOffUntil: Int64 = 0

    package init(now: @escaping () -> Int64) {
        self.now = now
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    package var contract: Int {
        get { locked { _contract } }
        set { locked { _contract = newValue } }
    }

    /// The app's switch and the property's, for taps.
    package var taps: Bool {
        get { locked { _taps } }
        set { locked { _taps = newValue } }
    }

    /// The scroll rules, where the app and the property capture scrolling, from contract 2.
    package var scroll: ScrollRules? {
        get { locked { _scroll } }
        set { locked { _scroll = newValue } }
    }

    /// The friction rules, where the app and the property capture friction, from contract 2.
    package var friction: FrictionRules? {
        get { locked { _friction } }
        set { locked { _friction = newValue } }
    }

    /// Until when, in microseconds since the epoch, the API said the property captures none of each.
    package var clicksOffUntil: Int64 {
        get { locked { _clicksOffUntil } }
        set { locked { _clicksOffUntil = newValue } }
    }

    package var scrollOffUntil: Int64 {
        get { locked { _scrollOffUntil } }
        set { locked { _scrollOffUntil = newValue } }
    }

    package var frictionOffUntil: Int64 {
        get { locked { _frictionOffUntil } }
        set { locked { _frictionOffUntil = newValue } }
    }

    package var tapsOn: Bool { taps && now() >= clicksOffUntil }

    package var scrollRules: ScrollRules? { now() >= scrollOffUntil ? scroll : nil }

    package var frictionRules: FrictionRules? { now() >= frictionOffUntil ? friction : nil }
}
