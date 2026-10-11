import Foundation

/// The core, `AutoCapture`'s counterpart and the Flutter SDK's `KontalaCore`: it stamps every event and sends it.
///
/// Plugins say what to capture and the core says how: the id, a UUIDv7 minted at capture so a retry is the same row;
/// the time, strictly increasing; the device and session, resolved per event, which slides the window; the app's
/// principal; consent; the view; and the context.
///
/// Every method runs on `scheduler`'s queue: the facade and the platform's signals post to it.
package final class Core: PluginContext, WebSharingHost {
    package static let meta = "meta.json"

    /// How long a switch the API said is off stays off before it is tried again.
    package static let learnedOffMicros: Int64 = 3600 * 1_000_000

    /// How long a screen's screen view waits for its web view's page to answer: a page's load on a slow network,
    /// which a screen view held this long costs only a later request.
    package static let containerWaitMicros: Int64 = 5_000_000

    /// The kinds that measure a view, which the API files under one and refuses without: under a withdrawn screen view
    /// they are not sent, where a tap or a custom event is filed under no view.
    package static let viewMeasures: Set<String> = [
        "scroll_depth",
        "swipe",
        "page_speed",
        "js_error",
        "rage_click",
        "dead_click",
        "page_restore",
        "view_time",
        "page_type",
    ]

    private let writeKey: String
    private let endpoint: String
    package let options: KontalaOptions
    private let platform: Platform
    package let scheduler: Scheduler
    private let http: Http
    private let clock: Clock

    package private(set) lazy var principal = Principal(warn: { [weak self] in self?.warn($0) })
    private lazy var contextBuilder = ContextBuilder(
        options: options.context, libraryVersion: sdkVersion, environment: platform)

    package private(set) lazy var hub = ScreenHub(
        onStart: { [weak self] k in
            guard let self = self else { return }
            self.navigating = true
            self.screens.navigationStarted(k)
            for l in self.navigationStart { l(k) }
        },
        onScreen: { [weak self] v in
            guard let self = self else { return }
            self.screens.screenShown(v)
            self.navigating = false
            self.pendingContainer = nil
            // A web view may be on show now, or gone: its pages' activity is read back while it is.
            self.webViews.screenChanged()
        },
        onIdle: { [weak self] in
            guard let self = self else { return }
            self.navigating = false
            // A web view attached during a navigation that showed no new screen, a dialog's, is the screen on show's
            // no more than any other's.
            self.pendingContainer = nil
            self.screens.navigationIdle()
            for l in self.navigationIdle { l() }
        },
        log: { [weak self] in self?.warn($0) })

    /// The visitor and the visit shared with the websites the app shows in a web view (WebSharing.swift).
    package private(set) lazy var webViews = WebSharing(host: self, platform: platform, scheduler: scheduler)

    /// A web view attached during a navigation, as the screen showing it was built, which its screen view is tied to.
    private var pendingContainer: WebAttachment?

    /// Whether a navigation has begun and its screen is not yet shown.
    private var navigating = false

    /// Screen views tied to the web view their screen shows, unsent, oldest first: one whose page answers the bridge is
    /// withdrawn, since the page's own page views are what the visitor saw there.
    private var containers: [(id: String, view: CapturedEvent, attachment: WebAttachment)] = []

    /// Screen views withdrawn as containers of web pages, by id, and the screen the latest showed while it lives.
    private var withdrawn = Set<String>()
    private var containerScreen: (screen: String?, attachment: WebAttachment)?

    /// The screen each recent view is on, by its id: what is filed under a view once the next has opened, as its speed
    /// is when its frames are reported late, is on that view's screen rather than the one on show.
    private var viewScreens: [String: String?] = [:]
    private var viewScreenOrder: [String] = []

    private lazy var gate = ConsentGate(
        initial: options.consent,
        holdMicros: KontalaOptions.millis(options.consentHold) * 1000,
        maxHeld: 250,
        scheduler: scheduler,
        release: { [weak self] events, state, held in self?.release(events, state, held) })

    package let screens = ScreensPlugin()
    package let lifecycle = LifecyclePlugin()
    package let engagement = EngagementPlugin()

    /// What the main thread reads before it reads a tap, a scroll or friction off the app's views.
    package private(set) lazy var switches = Switches(now: { [clock] in clock.nowMicros() })

    private var plugins: [KontalaPlugin] = []
    private var viewListeners: [(CapturedEvent) -> Void] = []
    private var viewEnd: [(CapturedEvent) -> Void] = []
    private var navigationStart: [(NavigationKind) -> Void] = []
    private var navigationIdle: [() -> Void] = []
    private var routeChanges: [() -> Void] = []
    private var hideListeners: [() -> Void] = []
    private var showListeners: [(Int64, Bool) -> Void] = []
    private var lifecycleListeners: [(AppState) -> Void] = []
    private var servedListeners: [(ServedConfig) -> Void] = []

    private var store: FileStore?
    private var identity: Identity?
    private var queue: EventQueue?
    private var sender: Sender?
    private var encoder: WireEncoder?
    private var config: ConfigClient?
    private var deviceIds: DeviceIds?
    package private(set) var facts: PlatformFacts?

    private var ready = false
    private var stopped = false
    private var optedOutFlag = false
    private var optOutCall: Bool?
    private var resetCall = false
    private var launchChecked = false
    private var hidden = false
    private var hiddenAt: Int64?
    private var viewAtHide: CapturedEvent?
    private var endingView = false
    private var early: [CapturedEvent] = []
    private var view: CapturedEvent?
    private var screenName: String?
    private var offUntil: [Capture: Int64] = [:]
    private var loaded: [() -> Void] = []
    private var loadDone = false

    /// Where the app is, as the platform's lifecycle last said.
    private var appState = AppState.resumed

    package init(
        writeKey: String, endpoint: String, options: KontalaOptions, platform: Platform, scheduler: Scheduler,
        http: Http, clock: Clock = Clock()
    ) {
        self.writeKey = writeKey
        self.endpoint = endpoint
        self.options = options
        self.platform = platform
        self.scheduler = scheduler
        self.http = http
        self.clock = clock
    }

    /// Starts capturing: binds the plugins and reads what an earlier launch left.
    package func start() {
        appState = platform.initialState()
        hidden = appState == .hidden
        var bound: [KontalaPlugin] = []
        // In the Flutter SDK's order, which is the order a view's measures are
        // queued in as it ends and as the app is hidden.
        bound.append(screens)
        if options.lifecycle { bound.append(lifecycle) }
        if options.screens { bound.append(engagement) }
        for p in bound {
            p.bind(self)
            plugins.append(p)
        }
        if options.screens { hub.start(foreground: !hidden) }
        load()
    }

    private func load() {
        let f = platform.facts()
        if stopped { return }
        defer {
            loadDone = true
            let waiting = loaded
            loaded.removeAll()
            for w in waiting { w() }
        }
        facts = f
        contextBuilder.setFacts(f)
        if contextBuilder.appId == nil {
            warn("the app id \"\(f.appId)\" is not one the Events API takes, so nothing can be sent")
        }
        let s = FileStore(baseDir: options.disableStorage ? nil : f.storageDir)
        store = s
        let meta = s.readJson(Core.meta) ?? JSONObject()
        optedOutFlag = optOutCall ?? (meta["opted_out"] == .bool(true))
        readLearned(meta)
        let allowed = storageAllowed
        s.writable = allowed
        let id = Identity(
            store: s, timeoutMillis: KontalaOptions.millis(options.sessionTimeout), pinnedDevice: options.deviceId,
            pinnedSession: options.sessionId)
        identity = id
        id.setStorageAllowed(allowed)
        if resetCall { id.forget() }
        let log: (String) -> Void = { [weak self] in self?.log($0) }
        let snd = Sender(
            endpoint: endpoint, writeKey: writeKey, store: s, clock: clock, libraryVersion: sdkVersion, http: http,
            scheduler: scheduler,
            onOutcome: { [weak self] batch, outcome in self?.outcome(batch, outcome) },
            onContractRefused: { [weak self] in self?.config?.refused() },
            log: log)
        sender = snd
        let enc = WireEncoder(clock: clock)
        encoder = enc
        let cfg = ConfigClient(
            endpoint: endpoint, writeKey: writeKey, store: s, clock: clock, libraryVersion: sdkVersion, http: http,
            scheduler: scheduler,
            onChange: { [weak self] in self?.servedChanged($0) },
            onHalt: { [weak snd] in snd?.halt() },
            log: log)
        config = cfg
        // The configuration an earlier launch kept, so this one captures and
        // writes by it from its first event; read again in the background.
        cfg.loadKept()
        enc.contract = cfg.current.contract
        publishSwitches()
        let q = EventQueue(
            store: s, encoder: enc, sender: snd, clock: clock, scheduler: scheduler,
            maxEvents: min(max(options.maxBatchEvents, 1), Limits.maxEventsPerRequest),
            intervalMicros: KontalaOptions.millis(options.flushInterval) * 1000,
            log: log)
        queue = q
        if optOutCall != nil { writeMeta() }
        if optedOutFlag {
            early.removeAll()
            q.clear()
        } else {
            q.restore()
        }
        ready = true
        cfg.refresh(force: true)
        if allowed { readIds() }
        // The websites the app shows are given its ids before any of them is likely to load, and what a page did
        // since is read back.
        webViews.loaded()
        screens.factsLoaded()
        let e = early
        early.removeAll()
        for x in e {
            x.context = contextBuilder.complete(x.context)
            admit(x)
        }
        launchRecord()
    }

    private var storageAllowed: Bool { gate.state == .granted && !options.disableStorage }

    // PluginContext.

    package var served: ServedConfig { config?.current ?? ServedConfig.contract1 }

    package func onServed(_ listener: @escaping (ServedConfig) -> Void) { servedListeners.append(listener) }

    private func servedChanged(_ c: ServedConfig) {
        encoder?.contract = c.contract
        log("the collector reads contract \(c.contract)")
        publishSwitches()
        for l in servedListeners { l(c) }
        webViews.originsChanged()
    }

    /// Tells the main thread what is captured and by which rules, as what is served and what the API said change.
    private func publishSwitches() {
        let s = served
        switches.contract = s.contract
        switches.clicksOffUntil = offUntil[.clicks] ?? 0
        switches.scrollOffUntil = offUntil[.scroll] ?? 0
        switches.frictionOffUntil = offUntil[.friction] ?? 0
        switches.taps = options.taps && s.clicks
        switches.scroll = options.scroll && s.contract >= 2 ? s.scroll : nil
        switches.friction = options.friction && s.contract >= 2 ? s.friction : nil
    }

    package var currentView: CapturedEvent? { view }

    package func captures(_ what: Capture) -> Bool {
        if let until = offUntil[what], clock.nowMicros() <= until { return false }
        let s = served
        switch what {
        case .clicks: return s.clicks
        case .customEvents: return s.customEvents
        case .screenProperties: return s.screenProperties
        case .scroll: return s.contract >= 2 && s.scroll != nil
        case .friction: return s.contract >= 2 && s.friction != nil
        }
    }

    package var sessionWouldRotate: Bool { identity?.wouldRotate(clock.nowMillis()) ?? false }

    package func onViewStart(_ listener: @escaping (CapturedEvent) -> Void) { viewListeners.append(listener) }

    package func onViewEnd(_ listener: @escaping (CapturedEvent) -> Void) { viewEnd.append(listener) }

    package func onNavigationStart(_ listener: @escaping (NavigationKind) -> Void) {
        navigationStart.append(listener)
    }

    package func onNavigationIdle(_ listener: @escaping () -> Void) { navigationIdle.append(listener) }

    package func onRouteChange(_ listener: @escaping () -> Void) { routeChanges.append(listener) }

    package func onHide(_ listener: @escaping () -> Void) { hideListeners.append(listener) }

    package func onShow(_ listener: @escaping (Int64, Bool) -> Void) { showListeners.append(listener) }

    package func onLifecycle(_ listener: @escaping (AppState) -> Void) { lifecycleListeners.append(listener) }

    package var elapsedMicros: Int64 { clock.elapsedMicros }

    /// Where the visitor is, by the platform's lifecycle: on show, inactive included, is in the app.
    private var presence: Presence { appState == .hidden ? .away : .here }

    package func emitEvent(
        _ kind: String, _ fields: JSONObject, startsView: Bool, screen: String?, viewOf: String?, namedUser: String?,
        namedOrg: String?, settleUntilMicros: Int64?, leaving: Bool, measure: Bool
    ) -> CapturedEvent? {
        if stopped || optedOutFlag { return nil }
        // What was measured of a view is filed under the visit in force: it is
        // no sign the visitor is here, and so starts no visit.
        let p: Presence = measure ? .away : (leaving ? .leaving : presence)
        if startsView, let ending = view, !endingView {
            // The view in force ends here: what was measured of it is queued
            // ahead of the page view that ends it, on its own screen.
            endingView = true
            for l in viewEnd { l(ending) }
            endingView = false
        }
        // A session that would start with this event starts with the screen
        // on show instead, so every visit has an entrance. Only an event in
        // the app starts one.
        if !startsView && view != nil && p == .here && sessionWouldRotate { screens.reopen() }
        // What is filed under a view is on that view's screen; under a screen view withdrawn as a container of web
        // pages, what measures the view is not sent, and anything else is filed under no view, on its screen.
        var under = startsView ? nil : (viewOf ?? view?.id)
        let on: String?
        if startsView {
            on = screen
        } else if let u = under, let s = viewScreens[u] {
            on = s
        } else {
            on = screenName
        }
        if let u = under, withdrawn.contains(u) {
            if Core.viewMeasures.contains(kind) { return nil }
            under = nil
        }
        let at = clock.stamp()
        let (user, org) = namedPrincipal(principal, user: namedUser, org: namedOrg)
        let e = CapturedEvent(
            id: Ids.uuidV7(floorDiv(at, 1000)),
            kind: kind,
            atMicros: at,
            monotonic: clock.monotonicMicros,
            fields: fields,
            context: contextBuilder.snapshot(on),
            view: under,
            namedUser: namedUser,
            namedOrg: namedOrg,
            presence: p,
            user: user,
            org: org
        )
        e.settleUntilMicros = settleUntilMicros
        if startsView {
            view = e
            screenName = screen
            viewScreens[e.id] = screen
            viewScreenOrder.append(e.id)
            if viewScreenOrder.count > 32 { viewScreens.removeValue(forKey: viewScreenOrder.removeFirst()) }
        }
        if options.debug { log("captured \(kind) \(describe(e))") }
        // A screen view of a screen showing an attached web view waits for the page to answer; one of a container
        // whose page answered already, a visit reopened on it, is withdrawn at once.
        var withdrawnNow = false
        if startsView {
            if let held = containerScreen, held.screen == screen, webViews.answered(held.attachment) {
                withdrawn.insert(e.id)
                withdrawnNow = true
            } else {
                let pending = pendingContainer
                pendingContainer = nil
                if let a = pending { tieContainer(e, a) }
            }
        }
        if withdrawnNow {
            log("a screen view of a web view's screen whose page answered was not sent: the page's are")
        } else if ready {
            admit(e)
        } else if early.count < 1000 {
            early.append(e)
        }
        if startsView { for l in viewListeners { l(e) } }
        return e
    }

    package func amend(_ event: CapturedEvent, _ change: (inout JSONObject) -> Void) -> Bool {
        if event.sealed { return false }
        change(&event.fields)
        queue?.touched()
        return true
    }

    package func renameScreen(_ screen: String) {
        screenName = screen
        if let v = view { viewScreens[v.id] = screen }
    }

    package func nowMicros() -> Int64 { clock.nowMicros() }

    package func fingerprint(_ done: @escaping (Int64?) -> Void) {
        platform.fingerprint { [weak self] print in
            guard let self = self else { return }
            self.scheduler.post { if !self.stopped { done(print) } }
        }
    }

    package func log(_ message: String) {
        if options.debug { platform.log("[kontala] \(message)") }
    }

    package func warn(_ message: String) {
        if options.debug || platform.debuggable { platform.log("[kontala] \(message)") }
    }

    private func describe(_ e: CapturedEvent) -> String {
        if let s = e.fields.obj("screen") { return s.str("name") ?? "" }
        if let el = e.fields.obj("element") {
            return "\(el.str("role") ?? "") \(el.str("text") ?? el.str("label") ?? el.str("id") ?? "")"
        }
        return e.view == nil ? "" : "on \(e.context.screen ?? "")"
    }

    // Stamping and sending.

    private func admit(_ e: CapturedEvent) {
        guard let id = identity else { return }
        let ids = id.resolve(floorDiv(e.atMicros, 1000), e.presence)
        e.device = ids.device
        e.session = ids.session
        gate.offer(e)
        webViews.identityResolved()
    }

    // Web views.

    /// Attaches a web view, for `Kontala.attachWebView`. Attached during a navigation, as the screen showing it is
    /// built, it ties the navigation's screen view to it; attached just after that screen view was captured, while it
    /// is unsent, that one. A web view a screen shows later in its life leaves the screen its own.
    package func attachWebView(_ host: WebViewHost, pending: Bool = false) -> WebAttachment {
        let a = webViews.attach(host)
        if navigating || view == nil || pending {
            pendingContainer = a
        } else if let v = view, !v.sealed, clock.nowMicros() - v.atMicros < 1_000_000 {
            tieContainer(v, a)
        }
        return a
    }

    /// Holds a screen view back until its web view's page has had time to answer, as a launch view waits for its link.
    private func tieContainer(_ v: CapturedEvent, _ webView: WebAttachment) {
        if containers.count >= 16 { containers.removeFirst() }
        containers.append((v.id, v, webView))
        let until = clock.nowMicros() + Core.containerWaitMicros
        if v.settleUntilMicros == nil || v.settleUntilMicros! < until { v.settleUntilMicros = until }
        queue?.touched()
        if webViews.answered(webView) { webPageAnswered(webView) }
    }

    package func webPageAnswered(_ attachment: WebAttachment) {
        // A web view that is a part of its screen, a banner or a card, leaves the screen its own; one that is the
        // screen, covering half the window or more, makes it a container of web pages.
        if containers.contains(where: { $0.attachment === attachment }) && webViews.coverage(attachment) < 0.5 {
            containers.removeAll { $0.attachment === attachment }
            return
        }
        for c in containers where c.attachment === attachment {
            containers.removeAll { $0.id == c.id }
            let v = c.view
            if v.sealed {
                log("a web view's page answered after its screen's screen view was sent, which stays")
                continue
            }
            // Wherever it waits, it is taken back there.
            let fromEarly = removeEarly(v)
            let fromGate = gate.withdraw(v.id)
            let fromQueue = queue?.withdraw(v) ?? false
            if !(fromEarly || fromGate || fromQueue) { continue }
            withdrawn.insert(v.id)
            containerScreen = (v.context.screen, attachment)
            log(
                "the screen view of \(v.context.screen ?? "a screen") was withdrawn: its web view's page views are the "
                    + "page's")
        }
    }

    private func removeEarly(_ v: CapturedEvent) -> Bool {
        guard let i = early.firstIndex(where: { $0 === v }) else { return false }
        early.remove(at: i)
        return true
    }

    package var webIdentity: Identity? { identity }

    package var webStorageAllowed: Bool { storageAllowed && !optedOutFlag && (store?.available ?? false) }

    package var pageConsent: KontalaConsent { optedOutFlag ? .denied : gate.state }

    package var appStamp: JSONObject? {
        guard let f = facts else { return nil }
        var m = JSONObject()
        m["id"] = .string(f.appId)
        if let v = f.appVersion { m["version"] = .string(v) }
        if let v = f.appBuild { m["build"] = .string(v) }
        m["mode"] = .string(f.buildMode)
        if f.isVirtual { m["virtual"] = .bool(true) }
        m["sdk"] = .string(sdkLibraryName)
        m["sdk_version"] = .string(sdkVersion)
        return m
    }

    package var servedOrigins: [WebOrigin] { served.webOrigins }

    package var optionOrigins: [String] { options.webOrigins }

    package func whenLoaded(_ then: @escaping () -> Void) {
        if loadDone { then() } else { loaded.append(then) }
    }

    package func nowMillis() -> Int64 { clock.nowMillis() }

    /// Runs [then] once the websites the app shows have its ids, or have none to be given.
    package func whenWebReady(_ then: @escaping () -> Void) {
        whenLoaded { [weak self] in self?.webViews.whenReady(then) }
    }

    private func release(_ events: [CapturedEvent], _ state: KontalaConsent, _ held: Bool) {
        guard let q = queue, let id = identity, !optedOutFlag else { return }
        // Held events are stamped with the ids the rest of the visit carries:
        // a returning visitor's stored device is legible only once consent is.
        var shared: Resolved?
        if held && !events.isEmpty {
            let p = events.map(\.presence).min(by: { $0.rank < $1.rank }) ?? .here
            shared = id.resolve(clock.nowMillis(), p)
        }
        for e in events {
            if state != .granted && grantOnlyKinds.contains(e.kind) {
                log("a \(e.kind) leaves only on a grant, and was dropped")
                continue
            }
            e.consent = state.wire
            // The device's ids ride on a granted event alone.
            if state == .granted, let ids = deviceIds, !ids.isEmpty { e.context.ids = ids }
            if let s = shared {
                e.device = s.device
                e.session = s.session
            }
            if !beforeSend(e) { continue }
            q.add(e)
        }
    }

    private func beforeSend(_ e: CapturedEvent) -> Bool {
        guard let hook = options.beforeSend else { return true }
        let element = e.fields.obj("element")
        let props = e.fields.obj("properties")
        let data = KontalaEventData(
            id: e.id,
            name: e.kind,
            timestamp: Date(timeIntervalSince1970: Double(e.atMicros) / 1_000_000),
            screen: e.context.screen,
            properties: props?.foundation,
            elementText: element?.str("text"),
            elementLabel: element?.str("label")
        )
        let edited: KontalaEventData?
        do {
            edited = try hook(data)
        } catch {
            log("beforeSend threw (\(error)), and the event was dropped")
            return false
        }
        guard let out = edited else { return false }
        if e.kind != "click" {
            if let safe = safeProperties(out.properties, log: { [weak self] in self?.log($0) }) {
                e.fields["properties"] = .object(safe)
            } else {
                e.fields.removeValue(forKey: "properties")
            }
        }
        if var edited = element {
            let text = out.elementText.map { collapse($0, Limits.maxText) } ?? ""
            let label = out.elementLabel.map { cutBytes(collapse($0, Limits.maxText), Limits.maxAttribute) } ?? ""
            edited.removeValue(forKey: "text")
            edited.removeValue(forKey: "label")
            if !text.isEmpty { edited["text"] = .string(text) }
            if !label.isEmpty { edited["label"] = .string(label) }
            e.fields["element"] = .object(edited)
        }
        return true
    }

    private func outcome(_ batch: SealedBatch, _ outcome: SendOutcome) {
        switch outcome {
        case .delivered(let accepted, let refused, let warnings):
            log("sent \(batch.events) events: \(accepted) stored")
            for r in refused {
                log("event \(r.index) was refused (\(r.code)): \(r.message)")
                learn(r)
            }
            for w in warnings { log("event \(w.index): \(w.code): \(w.message)") }
        case .dropped(let status, let code, let message):
            warn("a request was refused whole (\(status) \(code)): \(message)")
        case .halted(let code):
            warn("the write key was refused (\(code)): nothing more is sent until the app starts again")
        }
    }

    private func learn(_ r: Refusal) {
        switch r.code {
        case "clicks_off": turnOff(.clicks)
        case "source_not_captured": turnOff(.customEvents)
        case "scroll_off": turnOff(.scroll)
        case "friction_off": turnOff(.friction)
        case "invalid_context":
            if r.message.contains("timezone") { contextBuilder.timezoneRefused = true }
            if r.message.contains("locale") { contextBuilder.localeRefused = true }
        default: break
        }
    }

    private func turnOff(_ what: Capture) {
        if !captures(what) { return }
        offUntil[what] = clock.nowMicros() + Core.learnedOffMicros
        log("the property captures no \(what.stored), so none is sent for an hour")
        publishSwitches()
        writeMeta()
    }

    private func readLearned(_ meta: JSONObject) {
        guard let off = meta.obj("off") else { return }
        for c in Capture.allCases {
            guard let ms = off.long(c.stored) else { continue }
            let until = ms * 1000
            if until > clock.nowMicros() { offUntil[c] = until }
        }
    }

    /// Writes what the SDK remembers between launches: the visitor's opt-out, which is kept whatever consent says,
    /// and, only while consent is granted, the launch record and the switches the API said are off.
    private func writeMeta(_ launch: JSONObject? = nil) {
        guard let s = store else { return }
        let old = s.readJson(Core.meta) ?? JSONObject()
        if !s.writable {
            if optedOutFlag {
                s.writeJson(Core.meta, ["opted_out": true], essential: true)
            } else if old["opted_out"] == .bool(true) {
                s.delete(Core.meta)
            }
            return
        }
        var m = old
        if let l = launch { m.merge(l) }
        m["opted_out"] = .bool(optedOutFlag)
        var off = JSONObject()
        for c in Capture.allCases { if let v = offUntil[c] { off[c.stored] = .int(floorDiv(v, 1000)) } }
        m["off"] = .object(off)
        s.writeJson(Core.meta, m, essential: optedOutFlag)
    }

    /// Whether this launch is the app's first, or its first since an update, read once storage is allowed, which
    /// consent may hold back past launch.
    private func launchRecord() {
        if launchChecked { return }
        guard let s = store, let f = facts, s.available, s.writable else {
            // Without storage every launch would look like the first: there is no
            // record, and the launch's open goes ahead without one.
            if options.lifecycle { lifecycle.launchRecord(nil) }
            return
        }
        launchChecked = true
        let meta = s.readJson(Core.meta) ?? JSONObject()
        let installed = meta["launched"] != .bool(true)
        let version = f.appVersion
        let build = f.appBuild
        let previousVersion = meta.str("version")
        let previousBuild = meta.str("build")
        let updated = !installed && (previousVersion != version || previousBuild != build)
        writeMeta(["launched": true, "version": JSON(version), "build": JSON(build)])
        if !options.lifecycle { return }
        lifecycle.launchRecord(
            LaunchRecord(
                installed: installed, updated: updated, version: version, build: build,
                previousVersion: previousVersion, previousBuild: previousBuild))
    }

    /// The platform's lifecycle changed: the plugins hear it first, then the core acts on it.
    package func lifecycleChanged(_ state: AppState) {
        if stopped { return }
        appState = state
        for l in lifecycleListeners { l(state) }
        switch state {
        case .inactive:
            queue?.save()
        case .hidden:
            if hidden { return }
            hidden = true
            hiddenAt = clock.elapsedMicros
            viewAtHide = view
            // What the visitor saw is queued before anything is sealed.
            for l in hideListeners { l() }
            hub.setForeground(false)
            // Held events leave as unknown, since the app may never come back.
            gate.onHidden()
            identity?.flush()
            queue?.onHidden()
            webViews.hidden()
            backgroundFlush()
        case .resumed:
            if !hidden { return }
            hidden = false
            hub.setForeground(true)
            if view != nil && sessionWouldRotate { screens.reopen() }
            // Opened again by this core, or by an event a plugin sent on the
            // way back in, such as app_opened.
            let reopened = view !== viewAtHide
            let away = hiddenAt.map { clock.elapsedMicros - $0 } ?? 0
            for l in showListeners { l(away, reopened) }
            sender?.sendNow()
            // What is served may have changed while the app was away, and so
            // may whether the visitor allows ad tracking.
            config?.refresh()
            if storageAllowed { readIds() }
            webViews.resumed()
        }
    }

    /// The first frame of the launch was drawn: a launch nothing named is filed as `/`.
    package func firstFrame() {
        if stopped { return }
        if options.screens {
            hub.launchCheck()
        } else if options.lifecycle {
            lifecycle.firstFrame()
        }
    }

    /// The app that opened the launch's link, which the platform says after the SDK started: the launch view takes it
    /// while it is unsent.
    package func launchReferrer(_ referrer: String) {
        guard var f = facts, f.referrer != referrer else { return }
        f.referrer = referrer
        facts = f
        screens.factsLoaded()
    }

    /// Any screen or dialog opened or closed: an answer to a tap.
    package func routeChanged() {
        for l in routeChanges { l() }
        webViews.screenChanged()
    }

    /// iOS gives an app no time once it is hidden, so the flush holds a background task while it is in flight.
    private func backgroundFlush() {
        guard let s = sender else { return }
        let task = platform.beginBackgroundTask()
        var ended = false
        let end = { [platform] in
            if ended { return }
            ended = true
            platform.endBackgroundTask(task)
        }
        let timeout = scheduler.schedule(25_000_000) { end() }
        s.whenIdle {
            timeout.cancel()
            end()
        }
    }

    // The app's calls.

    package func identify(_ user: String?, _ org: String?, _ traits: JSONObject?) {
        principal.set(user: user, org: org)
        webViews.principalChanged()
        guard let t = traits, !t.isEmpty, captures(.customEvents) else { return }
        guard let safe = safeProperties(t, log: { [weak self] in self?.log($0) }) else { return }
        emit("identify", ["properties": .object(safe)])
    }

    package func reset() {
        principal.set()
        if let id = identity { id.forget() } else { resetCall = true }
        // The pages the app shows forget the visitor with it.
        webViews.forgotten()
    }

    package var optedOut: Bool { optOutCall ?? optedOutFlag }

    package func optOut(_ out: Bool) {
        optOutCall = out
        optedOutFlag = out
        if out {
            gate.clear()
            early.removeAll()
            queue?.clear()
            identity?.forget()
            webViews.forgotten()
        } else {
            webViews.consentChanged()
        }
        writeMeta()
    }

    package var consentState: KontalaConsent { gate.state }

    package func consent(_ state: KontalaConsent) {
        let allowed = state == .granted && !options.disableStorage
        store?.writable = allowed
        identity?.setStorageAllowed(allowed)
        if !allowed { queue?.save() }
        if state != .granted { deviceIds = nil }
        gate.set(state)
        if allowed && ready {
            launchRecord()
            config?.keep()
        }
        if state == .granted && ready { readIds() }
        // The pages the app shows are told, and their cookies follow it.
        webViews.consentChanged()
    }

    /// Reads the platform's ids for the device, which ride on granted events from then on: read only once consent is
    /// granted, since reading an id off a device needs the same consent as storing one, and again as the app comes
    /// back, since ad tracking can change in Settings.
    private func readIds(_ done: (() -> Void)? = nil) {
        if !options.context.deviceIds || gate.state != .granted {
            done?()
            return
        }
        platform.deviceIds { [weak self] ids in
            guard let self = self else { return }
            self.scheduler.post {
                if !self.stopped && self.gate.state == .granted, let ids = ids { self.deviceIds = ids }
                done?()
            }
        }
    }

    package func requestTrackingAuthorization(_ done: @escaping (String?) -> Void) {
        platform.requestTrackingAuthorization { [weak self] status in
            guard let self = self else { return }
            self.scheduler.post {
                if self.storageAllowed { self.readIds { done(status) } } else { done(status) }
            }
        }
    }

    package func track(_ name: String, _ properties: JSONObject?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty {
            warn("track: an event needs a name")
            return
        }
        if reservedEventNames.contains(canonicalEventName(n)) {
            warn("track: \"\(n)\" is a name Kontala gives its own events; choose another")
            return
        }
        if !captures(.customEvents) { return }
        var fields = JSONObject()
        if let safe = safeProperties(properties, log: { [weak self] in self?.log($0) }) {
            fields["properties"] = .object(safe)
        }
        emit(n, fields)
    }

    package func register(_ properties: JSONObject) { screens.register(properties) }

    package func unregister(_ key: String) { screens.unregister(key) }

    package func pageType(_ type: KontalaPageType) { screens.pageType(type) }

    package func screen(_ name: String, _ pageType: KontalaPageType?, _ properties: JSONObject?) {
        hub.manual(name, ScreenDeclaration(pageType: pageType, properties: properties))
    }

    package func screenData(_ properties: JSONObject) { screens.screenData(properties) }

    /// The app said its screen is fully displayed: the frame after it is its time to full display.
    package func screenReady() {
        if stopped || view == nil || !options.friction || !options.screens || !captures(.friction) { return }
        if served.contract < 2 { return }
        platform.screenReady()
    }

    /// Sends everything queued now; [done] is told once nothing is in flight.
    package func flush(_ done: @escaping () -> Void) {
        let go = { [weak self] in
            guard let q = self?.queue else { return done() }
            q.flush(done)
        }
        if loadDone { go() } else { loaded.append(go) }
    }

    package func stop() {
        if stopped { return }
        stopped = true
        hub.stop()
        switches.taps = false
        switches.scroll = nil
        switches.friction = nil
        for p in plugins { p.unbind() }
        webViews.stop()
        gate.dispose()
        identity?.flush()
        queue?.dispose()
        sender?.close()
        config?.close()
    }
}

extension Presence {
    /// How present the visitor was: in the app before leaving it, leaving before away.
    fileprivate var rank: Int {
        switch self {
        case .here: return 0
        case .leaving: return 1
        case .away: return 2
        }
    }
}
