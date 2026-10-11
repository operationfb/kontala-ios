#if os(iOS)
    import AppTrackingTransparency
    import Foundation
    import KontalaCore
    import UIKit
    import WebKit
    import os

    /// iOS as the core needs it: the app and the device; the device's own ids and App Tracking Transparency's prompt;
    /// the background time a flush needs once the app is hidden; and the cookie store every web view of the app
    /// shares.
    ///
    /// The core calls it on its own queue; whatever UIKit or WebKit answers only on the main thread is asked there,
    /// and answered back through the callback, and nothing reads a file on the main thread.
    final class ApplePlatform: Platform {
        private let fromUIKit: PlatformFacts
        private let app: UIApplication
        private let lock = NSLock()
        private var completed: PlatformFacts?
        private var mode: String?
        private var size: (Int, Int)?
        private var state: AppState
        private let logger = OSLog(subsystem: "la.konta.kontala", category: "Kontala")

        /// Reads what UIKit answers, on the main thread, where `Kontala.start` is called.
        init(app: UIApplication) {
            self.app = app
            fromUIKit = Facts.fromUIKit()
            switch app.applicationState {
            case .active: state = .resumed
            // An app is inactive as iOS draws its first frame: on show.
            case .inactive: state = .inactive
            case .background: state = .hidden
            @unknown default: state = .inactive
            }
            size = ApplePlatform.windowSize(app)
        }

        /// What UIKit said, with the storage directory and the build, which the file system says, read on the core's
        /// queue, once.
        func facts() -> PlatformFacts {
            lock.lock()
            let known = completed
            lock.unlock()
            if let f = known { return f }
            var f = fromUIKit
            f.storageDir = Facts.storageDirectory()
            f.buildMode = buildMode
            lock.lock()
            completed = f
            lock.unlock()
            return f
        }

        /// debug or release, from the provisioning profile, read once, by the core's queue as it starts.
        private var buildMode: String {
            lock.lock()
            defer { lock.unlock() }
            if let m = mode { return m }
            let m = Facts.buildMode()
            mode = m
            return m
        }

        var debuggable: Bool { buildMode == "debug" }

        func initialState() -> AppState { state }

        func localeTag() -> String? { Locale.preferredLanguages.first }

        func displaySize() -> (Int, Int)? {
            lock.lock()
            defer { lock.unlock() }
            return size
        }

        /// The size of the app's window in points, read again on the main thread as it may have changed.
        func windowChanged() {
            let s = ApplePlatform.windowSize(app)
            lock.lock()
            size = s
            lock.unlock()
        }

        private static func windowSize(_ app: UIApplication) -> (Int, Int)? {
            let window = app.windows.first { $0.isKeyWindow } ?? app.windows.first
            let bounds = window?.bounds ?? UIScreen.main.bounds
            let w = Int(bounds.width.rounded())
            let h = Int(bounds.height.rounded())
            return w > 0 && h > 0 ? (w, h) : nil
        }

        func deviceIds(_ done: @escaping (DeviceIds?) -> Void) {
            DispatchQueue.main.async { done(Facts.deviceIds()) }
        }

        /// Shows the App Tracking Transparency prompt, where the app's Info.plist says why: iOS ends an app that asks
        /// without NSUserTrackingUsageDescription. Answers the status the visitor chose.
        func requestTrackingAuthorization(_ done: @escaping (String?) -> Void) {
            DispatchQueue.main.async {
                guard #available(iOS 14, *) else {
                    done(Facts.trackingStatus())
                    return
                }
                guard Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") != nil else {
                    self.log(
                        "[kontala] requestTrackingAuthorization: the app's Info.plist has no NSUserTrackingUsageDescription, so iOS would end it"
                    )
                    done(nil)
                    return
                }
                ATTrackingManager.requestTrackingAuthorization { _ in
                    DispatchQueue.main.async { done(Facts.trackingStatus()) }
                }
            }
        }

        /// Time for the flush as the app is hidden: iOS suspends a hidden app within seconds, mid-request.
        func beginBackgroundTask() -> Any? {
            let task = BackgroundTask(app, "kontala.flush")
            return task.id == .invalid ? nil : task
        }

        func endBackgroundTask(_ token: Any?) {
            (token as? BackgroundTask)?.end()
        }

        func log(_ line: String) {
            os_log("%{public}@", log: logger, type: .info, line)
        }

        // The cookie store every web view of the app shares, WebKit's default website data store's: asynchronous,
        // and asked on the main thread alone. Its first use starts WebKit, so it is never asked as the app launches,
        // only once the core has websites to share and a grant to share them under.

        func writeWebCookies(_ cookies: [WebCookie], _ done: @escaping (Bool) -> Void) {
            DispatchQueue.main.async { WebCookieStore.write(cookies, done) }
        }

        func readWebCookies(
            _ origins: [WebOrigin], _ names: [String], _ done: @escaping ([[String: String]]?) -> Void
        ) {
            DispatchQueue.main.async { WebCookieStore.read(origins, names, done) }
        }

        func webViewShown(_ frames: Int, _ done: @escaping (Bool) -> Void) {
            DispatchQueue.main.async { [app] in WebViewFinder.look(app, frames: frames, done) }
        }
    }

    /// Time iOS gives a hidden app to finish something, ended once, by the SDK or as the time runs out.
    final class BackgroundTask {
        private let app: UIApplication
        private let lock = NSLock()
        private(set) var id = UIBackgroundTaskIdentifier.invalid

        init(_ app: UIApplication, _ name: String) {
            self.app = app
            let started = app.beginBackgroundTask(withName: name) { [weak self] in
                // Out of time: what is not sent goes with the next launch.
                self?.end()
            }
            lock.lock()
            id = started
            lock.unlock()
        }

        func end() {
            lock.lock()
            let ending = id
            id = .invalid
            lock.unlock()
            if ending != .invalid { app.endBackgroundTask(ending) }
        }
    }

    /// The default website data store's cookies, which every WKWebView of the app shares unless it was given a store
    /// of its own, as the Kontala tag writes and reads them.
    enum WebCookieStore {
        /// Writes [cookies] with the attributes the tag writes them with for its page's origin: host-only unless a
        /// Domain is named, Path=/, SameSite=Lax, and Secure on an https page. A Max-Age of 0 deletes the cookie.
        /// Answers once the store has them all, on the main thread.
        static func write(_ cookies: [WebCookie], _ done: @escaping (Bool) -> Void) {
            let store = WKWebsiteDataStore.default().httpCookieStore
            let group = DispatchGroup()
            var ok = true
            for c in cookies {
                let domain = WebCookies.domain(for: c.origin)
                if c.maxAgeSeconds <= 0 {
                    group.enter()
                    store.getAllCookies { all in
                        let gone = all.filter { $0.name == c.name && $0.path == "/" && $0.domain == domain }
                        let deleting = DispatchGroup()
                        for cookie in gone {
                            deleting.enter()
                            store.delete(cookie) { deleting.leave() }
                        }
                        deleting.notify(queue: .main) { group.leave() }
                    }
                    continue
                }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: c.name,
                    // The value as the tag encodes it, which its reader decodes.
                    .value: encodeComponent(c.value),
                    // A domain without a leading dot is sent to that host alone, as the tag's own host-only cookie
                    // is.
                    .domain: domain,
                    .path: "/",
                    .maximumAge: String(c.maxAgeSeconds),
                ]
                if c.origin.secure { properties[.secure] = "TRUE" }
                properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
                guard let cookie = HTTPCookie(properties: properties) else {
                    ok = false
                    continue
                }
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { done(ok) }
        }

        /// Reads the cookies [names] as each origin's pages see them, a map of the raw values each has, in the
        /// origins' order.
        static func read(_ origins: [WebOrigin], _ names: [String], _ done: @escaping ([[String: String]]?) -> Void) {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                let stored = all.map {
                    StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure)
                }
                done(origins.map { WebCookies.pick(stored, for: $0, names) })
            }
        }
    }

    /// Whether a web view is on show in a window of the app's: one in a window, not hidden, faded out or empty, and
    /// in no hidden view.
    enum WebViewFinder {
        /// The most views looked at in one look, so a screen of thousands costs a frame at most.
        static let budget = 2000

        static func look(_ app: UIApplication, frames: Int, _ done: @escaping (Bool) -> Void) {
            if shown(app) || frames <= 1 {
                done(shown(app))
                return
            }
            NextFrame.after { look(app, frames: frames - 1, done) }
        }

        static func shown(_ app: UIApplication) -> Bool {
            var left = budget
            for window in app.windows where !window.isHidden && window.alpha > 0.01 {
                if contains(window, &left) { return true }
            }
            return false
        }

        private static func contains(_ view: UIView, _ left: inout Int) -> Bool {
            if left <= 0 || view.isHidden || view.alpha <= 0.01 { return false }
            left -= 1
            if view is WKWebView { return view.bounds.width > 0 && view.bounds.height > 0 && view.window != nil }
            for sub in view.subviews where contains(sub, &left) { return true }
            return false
        }
    }

    /// Runs a block at the next frame the display draws, once.
    final class NextFrame {
        private var link: CADisplayLink?
        private let block: () -> Void
        private var keep: NextFrame?

        private init(_ block: @escaping () -> Void) {
            self.block = block
        }

        static func after(_ block: @escaping () -> Void) {
            let f = NextFrame(block)
            f.keep = f
            let link = CADisplayLink(target: f, selector: #selector(fire))
            f.link = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func fire() {
            link?.invalidate()
            link = nil
            keep = nil
            block()
        }
    }
#endif
