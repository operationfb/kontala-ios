/// A web view attached to Kontala, as `Kontala.attachWebView` hands it over: what its main frame shows, and a way to
/// run JavaScript there.
package protocol WebViewHost: AnyObject {
    /// The main frame's URL now, or nil before anything loaded, and the share of its window the web view covers, from
    /// 0 to 1: read on the main thread, and answered on any.
    func inspect(_ done: @escaping (_ url: String?, _ coverage: Double) -> Void)

    /// Runs [source] in the main frame.
    func runJavaScript(_ source: String)
}

/// A web view attached to the core: what a page posted on the bridge, and the web view going.
package protocol WebAttachment: AnyObject {
    /// What a page posted on `WebViews.bridgeChannel`, on the core's queue.
    func receive(_ message: String)

    /// The web view is gone.
    func detach()
}

/// A cookie for the web views' cookie store: what the tag writes for [origin]'s pages.
package struct WebCookie: Equatable {
    package let origin: WebOrigin
    package let name: String
    package let value: String
    package let maxAgeSeconds: Int64

    package init(_ origin: WebOrigin, _ name: String, _ value: String, _ maxAgeSeconds: Int64) {
        self.origin = origin
        self.name = name
        self.value = value
        self.maxAgeSeconds = maxAgeSeconds
    }

    package var url: String { origin.url }

    /// Byte for byte the tag's own write; a Max-Age of 0 deletes it.
    package var header: String { cookieHeader(name, value, maxAgeSeconds, origin) }
}

/// What the sharing reads of the running SDK.
package protocol WebSharingHost: AnyObject {
    /// The ids, once the SDK has loaded them.
    var webIdentity: Identity? { get }

    /// Whether the ids may be written to the device: consent granted, and storage not switched off.
    var webStorageAllowed: Bool { get }

    /// The consent a page is told: the app's, and denied for a visitor who opted out.
    var pageConsent: KontalaConsent { get }

    /// What the visitor answered in the app's consent manager, which a page records as the answer of the source
    /// `app`; nil while the SDK records none.
    var pageSignals: KontalaConsentSignals? { get }

    var principal: Principal { get }

    /// The app as a page is told it: its id, version, build, how it was built, whether it runs on a simulator, and
    /// the SDK, or nil before the platform has said.
    var appStamp: JSONObject? { get }

    /// The websites the property names, as the collector serves them.
    var servedOrigins: [WebOrigin] { get }

    /// The websites the app names itself, in its options.
    var optionOrigins: [String] { get }

    /// Runs [then] once the SDK has loaded what it keeps, which an answer waits for.
    func whenLoaded(_ then: @escaping () -> Void)

    func nowMillis() -> Int64

    func log(_ message: String)

    /// A page with the tag answered on [attachment]'s web view, which makes the screen showing it a container.
    func webPageAnswered(_ attachment: WebAttachment)
}

/// The app's side of sharing its visitor and its visit with the websites it shows in a web view (collector/webview),
/// both ways, the Flutter SDK's `core/web_sharing.dart`:
/// - **The cookie handover**, with no call of the app's: the device and the session are written into the cookie store
///   the app's web views share, as the tag on those websites writes them, for each website's origin, so a page reads
///   the app's ids; and `pt_sid` is read back, so the page's activity slides the app's visit (`Identity.mergeWeb`).
///   Written as the SDK loads, as a session starts or changes and at most every 30 seconds as it slides, and as the
///   app is hidden; read back as the app comes back, at every screen change, and every minute while a web view is on
///   show. Only while consent is granted: a change away from it deletes them, as the tag's own `clear` does.
/// - **The bridge**, for a web view attached with `Kontala.attachWebView`: a page on one of the websites that says
///   hello is told the app's context (its ids, consent and what the visitor answered in its consent manager,
///   signed-in user and the app), again whenever that changes, and its activity and own sign-in are taken.
///
/// Every method runs on the core's queue; the platform's answers are posted back to it.
package final class WebSharing {
    /// How often the cookies are read back while a web view is on show.
    package static let pollMicros: Int64 = 60_000_000

    /// The least time between two contexts that only slide the session.
    package static let pushIntervalMillis: Int64 = 60_000

    /// The most web views attached at once: each holds its web view, weakly, so an app that never detaches one does
    /// not keep every web view it ever showed.
    package static let maxAttachments = 16

    /// How long the first write may hold a web view at launch.
    package static let readyWaitMicros: Int64 = 500_000

    /// The longest message of a page read, far past any of the bridge's.
    package static let maxMessage = 8 * 1024

    private static let names = [WebViews.deviceCookie, WebViews.sessionCookie]

    private unowned let host: WebSharingHost
    private let platform: Platform
    private let scheduler: Scheduler

    private var attachments: [Attachment] = []
    private var poll: Cancellable?
    private var polling = false
    private var foreground = true
    private var stopped = false
    private var readyDone = false
    private var readyWaiters: [() -> Void] = []

    /// What the cookies were last written with, the device and the session, and when.
    private var written: (String, String)?
    private var writtenAt: Int64?

    /// The websites the app shows: the property's, then the app's own option, each origin once.
    package private(set) var origins: [WebOrigin] = []

    package init(host: WebSharingHost, platform: Platform, scheduler: Scheduler) {
        self.host = host
        self.platform = platform
        self.scheduler = scheduler
    }

    /// Runs [then] once the first write of the cookies is done, or has nothing to do: what a web view at launch
    /// awaits.
    package func whenReady(_ then: @escaping () -> Void) {
        if readyDone { then() } else { readyWaiters.append(then) }
    }

    private func completeReady() {
        if readyDone { return }
        readyDone = true
        let waiting = readyWaiters
        readyWaiters.removeAll()
        for w in waiting { w() }
    }

    /// Whether the cookies are shared: there are websites, and the ids may be written to the device.
    private var active: Bool { !origins.isEmpty && host.webStorageAllowed && !stopped }

    /// Reads the websites again, from what is served and the app's option.
    package func originsChanged() {
        var out = host.servedOrigins
        for o in host.optionOrigins {
            guard let w = WebOrigin.parse(o) else {
                host.log("webOrigins: \"\(o)\" is not an origin, such as https://shop.example.com, and was left out")
                continue
            }
            if !out.contains(where: { $0.value == w.value }) { out.append(w) }
        }
        let changed = out.count != origins.count || !origins.allSatisfy { out.contains($0) }
        origins = out
        if !changed { return }
        if active { write(force: true) }
        // Websites named once the SDK was ready, by a configuration that answered late, are read back from then on too.
        if readyDone { updatePoll() }
    }

    /// The SDK has loaded its ids: the page's activity is read back and the app's ids written before `whenReady`
    /// answers, within half a second, so a platform that never answers holds no web view back. A first launch keeps no
    /// configuration yet, so the websites only it names are not known here: they are written as it answers.
    package func loaded() {
        originsChanged()
        if !active {
            completeReady()
            updatePoll()
            return
        }
        var finished = false
        let finish = { [weak self] in
            if finished { return }
            finished = true
            self?.completeReady()
            self?.updatePoll()
        }
        // A store that does not answer in time: the next write will.
        let timeout = scheduler.schedule(WebSharing.readyWaitMicros) { finish() }
        readBack { [weak self] in
            self?.write(force: true) {
                timeout.cancel()
                finish()
            }
        }
    }

    /// An event was stamped with the ids: the cookies are written at once for a session they do not hold yet, and at
    /// most every 30 seconds as it only slides; and attached pages are told the same, at most every minute as it only
    /// slides.
    package func identityResolved() {
        if stopped { return }
        if active { write() }
        for a in attachments where a.answered != nil { push(a) }
    }

    /// Consent changed: the cookies are written under a grant and deleted otherwise, and attached pages told.
    package func consentChanged() {
        if stopped { return }
        if active { write(force: true) } else { clear() }
        updatePoll()
        pushAll()
    }

    /// The app's signed-in user changed: attached pages are told.
    package func principalChanged() { pushAll() }

    /// What the visitor answered in a consent manager changed: attached pages are told, and nothing about the cookies
    /// changes with it.
    package func signalsChanged() {
        if stopped { return }
        pushAll()
    }

    /// The app forgot its visitor: the cookies go, and the next event writes the new ids.
    package func forgotten() {
        clear()
        pushAll()
    }

    /// The app came back to the foreground: what a page did meanwhile is read.
    package func resumed() {
        foreground = true
        if active { readBack() }
        updatePoll()
    }

    /// The app went to the background: the cookies are written as they are.
    package func hidden() {
        foreground = false
        poll?.cancel()
        poll = nil
        polling = false
        if active { write(force: true) }
    }

    /// The screen on show changed: a web view may be on show now, or gone.
    package func screenChanged() {
        if active { readBack() }
        updatePoll(frames: 3)
    }

    /// Polls while a web view is on show in the foreground, and only then, so nothing runs a timer while the app is
    /// idle; a web view of a screen just shown is looked for over its next [frames] frames, since it may be laid out
    /// only then.
    private func updatePoll(frames: Int = 1) {
        if !wantPoll(true) {
            stopPoll()
            return
        }
        platform.webViewShown(frames) { [weak self] shown in
            guard let self = self else { return }
            self.scheduler.post { self.pollWhile(shown) }
        }
    }

    private func wantPoll(_ shown: Bool) -> Bool { shown && !stopped && foreground && active }

    private func pollWhile(_ shown: Bool) {
        if !wantPoll(shown) {
            stopPoll()
        } else if !polling {
            polling = true
            host.log("a web view is on show: its pages' visit is read back every minute")
            schedulePoll()
        }
    }

    private func schedulePoll() {
        poll = scheduler.schedule(WebSharing.pollMicros) { [weak self] in
            guard let self = self else { return }
            self.poll = nil
            if !self.polling || !self.wantPoll(true) { return }
            self.readBack()
            // Whether a web view is still on show decides the next.
            self.platform.webViewShown(1) { [weak self] shown in
                guard let self = self else { return }
                self.scheduler.post {
                    if self.polling && self.poll == nil && self.wantPoll(shown) {
                        self.schedulePoll()
                    } else {
                        self.pollWhile(shown)
                    }
                }
            }
        }
    }

    private func stopPoll() {
        poll?.cancel()
        poll = nil
        if !polling { return }
        polling = false
        host.log("no web view is on show: its pages' visit is read back no more")
    }

    // The cookies.

    private func write(force: Bool = false, then: (() -> Void)? = nil) {
        guard let id = host.webIdentity, let s = id.sessionNow(), active else {
            then?()
            return
        }
        let device = id.deviceId
        let now = host.nowMillis()
        let same = written.map { $0 == (device, s.id) } ?? false
        if !force, same, let at = writtenAt, now - at < WebViews.writeIntervalMillis {
            then?()
            return
        }
        written = (device, s.id)
        writtenAt = now
        let sessionAge = id.timeoutMillis / 1000 + WebViews.sessionExtraSeconds
        var cookies: [WebCookie] = []
        for o in origins {
            cookies.append(WebCookie(o, WebViews.deviceCookie, device, WebViews.deviceMaxAgeSeconds))
            cookies.append(WebCookie(o, WebViews.sessionCookie, s.value, sessionAge))
        }
        platform.writeWebCookies(cookies) { [weak self] ok in
            guard let self = self else { return }
            self.scheduler.post {
                if !ok { self.written = nil }
                then?()
            }
        }
    }

    private func clear() {
        written = nil
        if origins.isEmpty { return }
        var cookies: [WebCookie] = []
        for o in origins {
            cookies.append(WebCookie(o, WebViews.deviceCookie, "", 0))
            cookies.append(WebCookie(o, WebViews.sessionCookie, "", 0))
        }
        platform.writeWebCookies(cookies) { _ in }
    }

    /// Reads `pt_did` and `pt_sid` as each website's pages see them: a page's later activity slides the app's visit,
    /// or its own visit is taken where it began after the app's had lapsed, and a cookie that is not the app's is
    /// written over.
    private func readBack(_ then: (() -> Void)? = nil) {
        platform.readWebCookies(origins, WebSharing.names) { [weak self] values in
            guard let self = self else { return }
            self.scheduler.post { self.readBack(values, then) }
        }
    }

    private func readBack(_ values: [[String: String]]?, _ then: (() -> Void)?) {
        guard let values = values, let id = host.webIdentity, active else {
            then?()
            return
        }
        // A value as the tag reads it, decoded, and as it is where it does not decode: what the reader cannot parse
        // then holds no session.
        let read = values.map { v in v.mapValues { decodeComponent($0) ?? $0 } }
        var changed = false
        for v in read {
            if let s = WebSession.parse(v[WebViews.sessionCookie]), id.mergeWeb(s.id, s.lastSeen) { changed = true }
        }
        let s = id.sessionNow()
        if changed {
            host.log(
                "a website's pages were active: the app's visit is \(s?.id ?? "none"), last seen "
                    + "\(s.map { String($0.lastSeen) } ?? "never")")
        }
        let device = id.deviceId
        let stale =
            s != nil
            && read.contains { v in
                v[WebViews.deviceCookie] != device || WebSession.parse(v[WebViews.sessionCookie])?.id != s!.id
            }
        let done: () -> Void = { [weak self] in
            if changed { self?.pushAll() }
            then?()
        }
        if stale { write(force: true, then: done) } else { done() }
    }

    // The bridge.

    /// Attaches a web view, which `Kontala.attachWebView` does for the app.
    package func attach(_ webView: WebViewHost) -> WebAttachment {
        if attachments.count >= WebSharing.maxAttachments { attachments.removeFirst().detached = true }
        let a = Attachment(owner: self, webView: webView)
        attachments.append(a)
        return a
    }

    fileprivate func received(_ a: Attachment, _ raw: String) {
        if stopped || a.detached { return }
        // A message of the bridge is a few hundred bytes; anything far longer is no message of it.
        if raw.utf16.count > WebSharing.maxMessage { return }
        switch PageMessage.read(raw, nonce: a.nonce) {
        case .hello(let challenge)?:
            answer(a, challenge: challenge)
        case .activity(let session)?:
            guard let id = host.webIdentity else { return }
            if id.mergeWeb(session.id, session.lastSeen) && active { write(force: true) }
            // A page holding another session than the app's is told the app's.
            if id.sessionNow()?.id != session.id { push(a, force: true) }
        case .identify(let user, let org)?:
            host.principal.setWeb(user: user, org: org)
        case nil:
            host.log("a web view posted a message that is not one of the bridge's, and it was ignored")
        }
    }

    /// Answers a page's hello: only in a main frame on one of the websites, once the SDK has its ids, echoing the
    /// hello's challenge, which the page takes its first context by. Each hello is answered with its own: a frame
    /// inside the page can reach the channel too, and its hello must not take the place of the page's.
    private func answer(_ a: Attachment, challenge: String?) {
        host.whenLoaded { [weak self, weak a] in
            guard let a = a else { return }
            a.webView.inspect { url, coverage in
                guard let self = self else { return }
                self.scheduler.post {
                    if self.stopped || a.detached { return }
                    guard let origin = self.origins.first(where: { $0.matches(url) }) else {
                        let from = PageUrl.of(url).map { "\($0.scheme)://\($0.host)" } ?? "nowhere"
                        self.host.log(
                            "a page in a web view said hello from \(from), which is none of the websites the app "
                                + "shows, and was not answered: name it in Kontala, or in webOrigins")
                        return
                    }
                    a.answered = origin
                    a.coverage = coverage
                    self.host.webPageAnswered(a)
                    self.push(a, force: true, challenge: challenge)
                }
            }
        }
    }

    private func pushAll() {
        for a in attachments where a.answered != nil { push(a, force: true) }
    }

    /// Tells an answered page the app's context: at once when anything but the session's last activity changed, and
    /// otherwise at most every `pushIntervalMillis`. An answer to a hello echoes its challenge; an update echoes none,
    /// since the page takes it by the nonce its first context gave.
    private func push(_ a: Attachment, force: Bool = false, challenge: String? = nil) {
        guard let origin = a.answered, let id = host.webIdentity, let app = host.appStamp, !a.detached, !stopped
        else { return }
        let now = host.nowMillis()
        // A page is given a session, and the one it is given starts now where the app has none yet: the visitor is
        // looking at the page.
        let s = id.sessionNow() ?? WebSession(id.resolve(now).session, now)
        let device = id.deviceId
        let consent = host.pageConsent.wire
        let signals = host.pageSignals?.toJson()
        let p = host.principal
        let said =
            "\(device)|\(s.id)|\(consent)|\(signals.map { Json.encode($0) } ?? "null")|\(p.user ?? "null")|\(p.org ?? "null")"
        if !force, said == a.said, let at = a.pushedAt, now - at < WebSharing.pushIntervalMillis { return }
        a.said = said
        a.pushedAt = now
        var context = JSONObject()
        context["v"] = .int(Int64(WebViews.bridgeVersion))
        context["nonce"] = .string(a.nonce)
        if let c = challenge { context["challenge"] = .string(c) }
        context["app"] = .object(app)
        context["device"] = .string(device)
        context["session"] = .string(s.id)
        context["last_seen"] = .int(s.lastSeen)
        context["consent"] = .string(consent)
        if let v = signals { context["consent_signals"] = .object(v) }
        if let u = p.user { context["user"] = .string(u) }
        if let o = p.org { context["org"] = .string(o) }
        // The origin is checked again in the page, for a navigation between the check above and this.
        let script =
            "(function(){if(location.origin!==\(Json.encode(.string(origin.value))))return;"
            + "(window.pageTrackerQueue=window.pageTrackerQueue||[]).push([\"app\",\(Json.encode(context))]);})();"
        a.webView.runJavaScript(script)
    }

    fileprivate func detach(_ a: Attachment) {
        a.detached = true
        attachments.removeAll { $0 === a }
    }

    /// Whether a page answered on [a], for the core's container rule, and the share of its window it covers.
    package func answered(_ a: WebAttachment) -> Bool {
        guard let a = a as? Attachment else { return false }
        return a.answered != nil && !a.detached
    }

    package func coverage(_ a: WebAttachment) -> Double { (a as? Attachment)?.coverage ?? 0 }

    /// Measures again the share of its window [a]'s web view covers, and runs [then] on the core's queue once it has.
    package func measure(_ a: WebAttachment, _ then: @escaping () -> Void) {
        guard let a = a as? Attachment, !a.detached else { return }
        a.webView.inspect { [weak self] _, coverage in
            guard let self = self else { return }
            self.scheduler.post {
                if self.stopped || a.detached { return }
                a.coverage = coverage
                then()
            }
        }
    }

    package func stop() {
        stopped = true
        poll?.cancel()
        poll = nil
        polling = false
        for a in attachments { a.detached = true }
        attachments.removeAll()
        completeReady()
    }

    fileprivate final class Attachment: WebAttachment {
        private weak var owner: WebSharing?
        /// The web view as the platform hands it over, which holds the platform's own weakly.
        let webView: WebViewHost

        /// The nonce the page is given with its context, which every message after its hello must carry: a frame of
        /// another origin cannot read it.
        let nonce: String = WebSharing.nonce()

        /// The website the app answered a page of this web view on, and the share of the window it covered then.
        var answered: WebOrigin?
        var coverage = 0.0
        var detached = false

        /// What the page was last told, and when.
        var said: String?
        var pushedAt: Int64?

        init(owner: WebSharing, webView: WebViewHost) {
            self.owner = owner
            self.webView = webView
        }

        func receive(_ message: String) { owner?.received(self, message) }

        func detach() {
            if let o = owner {
                o.detach(self)
            } else {
                detached = true
            }
        }
    }

    /// 16 random bytes, as the tag's nonce pattern takes them: long enough that no frame guesses them.
    private static func nonce() -> String {
        var g = SystemRandomNumberGenerator()
        let hex = Array("0123456789abcdef")
        var out = ""
        for _ in 0..<2 {
            let x = g.next() as UInt64
            for i in 0..<8 {
                let b = UInt8(truncatingIfNeeded: x >> (8 * UInt64(i)))
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
        return out
    }
}
