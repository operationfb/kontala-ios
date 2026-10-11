/// What a property captures, as its region's collector serves it (`ServedConfig`), and as the API's refusals say where
/// a collector serves nothing yet. `stored` is the name `meta.json` keeps a learned switch under, the Flutter SDK's.
package enum Capture: String, CaseIterable {
    /// Taps: refused as `clicks_off`.
    case clicks = "clicks"
    /// Custom events, the lifecycle's among them: refused as `source_not_captured`.
    case customEvents = "customEvents"
    /// A screen view's properties, its data layer.
    case screenProperties = "screenProperties"
    /// Scroll depth and swipes, from contract 2: refused as `scroll_off`.
    case scroll = "scroll"
    /// Errors, rage and dead taps, returns and screen speed, from contract 2: refused as `friction_off`.
    case friction = "friction"

    package var stored: String { rawValue }
}

/// Where the app is, as the platform's lifecycle says: the Flutter SDK's `AppLifecycleState`, with its hidden, paused
/// and detached one state, since a native app is told of no difference between them.
package enum AppState {
    /// On show and in front: an active scene.
    case resumed
    /// On show, not in front: a scene inactive, as on the way out, behind the app switcher or a system alert, and as
    /// iOS draws an app's first frame. On show.
    case inactive
    /// Not on show: in the background.
    case hidden
}

/// What the core offers a plugin: one way to emit, and every signal a plugin listens for. A plugin describes what to
/// capture; the core stamps the id, the time, the identity, the consent and the context around it. Everything here is
/// called on the core's queue.
package protocol PluginContext: AnyObject {
    var options: KontalaOptions { get }

    /// What the platform said about the app and the device, once it has.
    var facts: PlatformFacts? { get }

    /// What the region's collector serves this app: its contract and the property's sections.
    var served: ServedConfig { get }

    /// Told each time what is served changes, which may be after the plugin bound.
    func onServed(_ listener: @escaping (ServedConfig) -> Void)

    /// The page view in force, which every other event is filed under.
    var currentView: CapturedEvent? { get }

    /// Whether the property captures [what], as far as the API has said.
    func captures(_ what: Capture) -> Bool

    /// Stamps and queues an event. A `page_view` opens a view ([startsView]) named [screen]; any other event is filed
    /// under the view in force, or under [viewOf]. [namedUser] and [namedOrg] are who the event names itself, stamped
    /// in the halves the app's own identify leaves empty. [leaving] marks the event that says the visitor left the
    /// app, and [measure] one that says what was measured of a view, which is filed under the visit in force and
    /// neither keeps it going nor starts one.
    func emitEvent(
        _ kind: String, _ fields: JSONObject, startsView: Bool, screen: String?, viewOf: String?, namedUser: String?,
        namedOrg: String?, settleUntilMicros: Int64?, leaving: Bool, measure: Bool
    ) -> CapturedEvent?

    /// Time since the SDK started, on a clock a changed wall clock does not move, which every duration is measured on.
    var elapsedMicros: Int64 { get }

    /// Changes an event's fields while it is still unsent. Answers whether it was still unsent.
    func amend(_ event: CapturedEvent, _ change: (inout JSONObject) -> Void) -> Bool

    /// Renames the screen the view in force is on.
    func renameScreen(_ screen: String)

    /// Whether the next event in the app would start a new session, which a screen view should open rather than a tap.
    var sessionWouldRotate: Bool { get }

    /// Told after each page view is emitted.
    func onViewStart(_ listener: @escaping (CapturedEvent) -> Void)

    /// Told just before a page view opens a new view, while [listener]'s view is still the one in force.
    func onViewEnd(_ listener: @escaping (CapturedEvent) -> Void)

    /// Told as a navigation begins, before anything of the next screen.
    func onNavigationStart(_ listener: @escaping (NavigationKind) -> Void)

    /// Told when a navigation settled on the screen already on show.
    func onNavigationIdle(_ listener: @escaping () -> Void)

    /// Told when any screen or dialog was opened or closed: an answer to a tap.
    func onRouteChange(_ listener: @escaping () -> Void)

    /// Told as the app is hidden, once, before anything is sealed and sent.
    func onHide(_ listener: @escaping () -> Void)

    /// Told as the app is shown again, with how long it was away and whether its screen was opened again as a new
    /// visit's entrance.
    func onShow(_ listener: @escaping (_ awayMicros: Int64, _ reopened: Bool) -> Void)

    /// Told of each change of the app's lifecycle, before the core acts on it, as the Flutter SDK's plugins hear it
    /// first: `app_backgrounded` is queued before the hide's flush, and `app_opened` before the return's.
    func onLifecycle(_ listener: @escaping (AppState) -> Void)

    /// The SDK's own debug log, written when `KontalaOptions.debug` is on.
    func log(_ message: String)

    /// The time now, in microseconds since the epoch, from the clock every event is stamped by.
    func nowMicros() -> Int64

    /// The core's queue, for a plugin's own timers.
    var scheduler: Scheduler { get }

    /// A fingerprint of what the app shows, read on the main thread, which tells whether a tap was answered where
    /// nothing cheaper says: answered on the core's queue, nil where it could not be read.
    func fingerprint(_ done: @escaping (Int64?) -> Void)
}

extension PluginContext {
    /// `emitEvent`, with every argument but the kind and the fields its default.
    @discardableResult
    package func emit(
        _ kind: String, _ fields: JSONObject = JSONObject(), startsView: Bool = false, screen: String? = nil,
        viewOf: String? = nil, namedUser: String? = nil, namedOrg: String? = nil, settleUntilMicros: Int64? = nil,
        leaving: Bool = false, measure: Bool = false
    ) -> CapturedEvent? {
        emitEvent(
            kind, fields, startsView: startsView, screen: screen, viewOf: viewOf, namedUser: namedUser,
            namedOrg: namedOrg, settleUntilMicros: settleUntilMicros, leaving: leaving, measure: measure)
    }
}

/// A capture: what to capture and when, never how it is stamped or sent.
package protocol KontalaPlugin: AnyObject {
    var key: String { get }

    func bind(_ context: PluginContext)

    /// Releases whatever `bind` acquired.
    func unbind()
}

extension KontalaPlugin {
    package func unbind() {}
}
