/// What the stored launch record says about this launch: the first one Kontala could store anything on, or one with
/// another version or build than the last.
package struct LaunchRecord: Equatable {
    package var installed: Bool
    package var updated: Bool
    package var version: String?
    package var build: String?
    package var previousVersion: String?
    package var previousBuild: String?

    package init(
        installed: Bool, updated: Bool, version: String? = nil, build: String? = nil, previousVersion: String? = nil,
        previousBuild: String? = nil
    ) {
        self.installed = installed
        self.updated = updated
        self.version = version
        self.build = build
        self.previousVersion = previousVersion
        self.previousBuild = previousBuild
    }
}

/// The app's lifecycle as custom events: `app_installed`, `app_updated`, `app_opened` and `app_backgrounded`, each
/// filed under the screen it happened on. A launch's come after the launch's screen view, so they are filed under it
/// rather than at the app's root.
package final class LifecyclePlugin: KontalaPlugin {
    package let key = "lifecycle"

    private weak var ctx: PluginContext?
    private var viewSeen = false
    private var frameSeen = false
    private var openedSent = false
    private var record: LaunchRecord?
    private var recordKnown = false
    private var recordSent = false
    private var hidden = false
    private var shownAt: Int64?
    private var hiddenAt: Int64?

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        shownAt = context.nowMicros()
        context.onLifecycle { [weak self] in self?.state($0) }
        context.onViewStart { [weak self] _ in self?.viewStarted() }
    }

    private var on: Bool {
        guard let ctx = ctx else { return false }
        return ctx.options.lifecycle && ctx.captures(.customEvents)
    }

    private func viewStarted() {
        if viewSeen { return }
        viewSeen = true
        launchEvents()
    }

    /// What the core could read of the launch: its record, or nil where it can store nothing, which consent may change
    /// later in the launch. The launch's own events wait for it, so an install comes before its open however late the
    /// platform answers.
    package func launchRecord(_ record: LaunchRecord?) {
        recordKnown = true
        if let r = record { self.record = r }
        launchEvents()
    }

    /// With screens off, there is no launch view to wait for.
    package func firstFrame() {
        frameSeen = true
        launchEvents()
    }

    private func launchEvents() {
        guard let ctx = ctx else { return }
        let launched = viewSeen || (frameSeen && !ctx.options.screens)
        if !on || !launched || !recordKnown { return }
        if let r = record, !recordSent {
            recordSent = true
            if r.installed {
                track("app_installed", [("version", JSON(r.version)), ("build", JSON(r.build))])
            } else if r.updated {
                track(
                    "app_updated",
                    [
                        ("version", JSON(r.version)), ("build", JSON(r.build)),
                        ("previous_version", JSON(r.previousVersion)), ("previous_build", JSON(r.previousBuild)),
                    ])
            }
        }
        if !openedSent {
            openedSent = true
            track("app_opened", [("cold", .bool(true))])
        }
    }

    private func state(_ state: AppState) {
        guard let ctx = ctx else { return }
        switch state {
        case .hidden:
            if hidden { return }
            hidden = true
            let now = ctx.nowMicros()
            hiddenAt = now
            let shown = shownAt ?? now
            if on { track("app_backgrounded", [("foreground_ms", .int((now - shown) / 1000))], leaving: true) }
        case .resumed:
            if !hidden { return }
            hidden = false
            let now = ctx.nowMicros()
            shownAt = now
            let away: JSON = hiddenAt.map { .int((now - $0) / 1000) } ?? .null
            if on { track("app_opened", [("cold", .bool(false)), ("away_ms", away)]) }
        case .inactive:
            break
        }
    }

    private func track(_ name: String, _ properties: [(String, JSON)], leaving: Bool = false) {
        var props = JSONObject()
        for (k, v) in properties where !v.isNull { props[k] = v }
        var fields = JSONObject()
        if !props.isEmpty { fields["properties"] = .object(props) }
        ctx?.emit(name, fields, leaving: leaving)
    }
}

/// How long each screen view was on show, Firebase's engagement time, as a `view_time` row filed under its view: the
/// time it was the current screen while the app was in the foreground. A dialog over it keeps counting, since it is
/// still that screen.
///
/// Sent at the view's end (`view`) and as the app is hidden (`hide`), and again only when the time grew, so the last
/// screen before the app went away has a time too, which time on page, read from the next page view, never gives it.
/// Captured whatever the property's switches, as a page view is, from contract 2, and only on a grant, since it joins
/// by the view a redaction takes away.
package final class EngagementPlugin: KontalaPlugin {
    /// What sends a view_time: the app being hidden, or the next view opening (collector/engagement.Triggers).
    package static let triggers = ["hide", "view"]

    /// The longest time on show a view_time may say, a day: past it the collector reads a clock that jumped or a
    /// screen nobody was in front of, and refuses it (collector/engagement.MaxVisibleMS).
    package static let maxVisibleMs: Int64 = 24 * 60 * 60 * 1000

    package let key = "engagement"

    private weak var ctx: PluginContext?
    private var view: CapturedEvent?
    private var countedMicros: Int64 = 0
    private var since: Int64?
    private var sentMs: Int64 = 0
    private var hidden = false

    package init() {}

    package func bind(_ context: PluginContext) {
        ctx = context
        context.onViewStart { [weak self] in self?.started($0) }
        context.onViewEnd { [weak self] in self?.send($0, EngagementPlugin.triggers[1]) }
        context.onHide { [weak self] in self?.hide() }
        context.onShow { [weak self] _, _ in self?.show() }
    }

    private func started(_ v: CapturedEvent) {
        view = v
        countedMicros = 0
        sentMs = 0
        since = hidden ? nil : ctx?.elapsedMicros
    }

    private func visibleMicros() -> Int64 {
        guard let s = since, let ctx = ctx else { return countedMicros }
        return countedMicros + (ctx.elapsedMicros - s)
    }

    private func hide() {
        if let v = view { send(v, EngagementPlugin.triggers[0]) }
        countedMicros = visibleMicros()
        since = nil
        hidden = true
    }

    private func show() {
        hidden = false
        // A reopened screen is a new view, which is counting already.
        if since == nil { since = ctx?.elapsedMicros }
    }

    private func send(_ v: CapturedEvent, _ trigger: String) {
        guard let ctx = ctx, v === view, ctx.served.contract >= 2 else { return }
        let ms = visibleMicros() / 1000
        if ms <= sentMs || ms > EngagementPlugin.maxVisibleMs { return }
        sentMs = ms
        ctx.emit(
            "view_time", ["engagement": ["trigger": .string(trigger), "visible_ms": .int(ms)]], viewOf: v.id,
            measure: true)
    }
}
