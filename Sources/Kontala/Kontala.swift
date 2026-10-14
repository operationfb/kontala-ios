@_exported import KontalaCore

#if os(iOS)
    import Foundation
    import UIKit

    extension Kontala {
        private static var lifecycle: AppLifecycle?
        private static var measures: MeasureReaders?

        /// Starts capturing, as the app starts: in `App.init` or `application(_:didFinishLaunchingWithOptions:)`, on
        /// the main thread. [writeKey] is the property's public write key, and [endpoint] the Events API URL Kontala
        /// shows beside it.
        ///
        /// SwiftUI runs a SwiftUI app's `App.init` before UIKit has made the app, so a start there begins as the app
        /// finishes launching, where an app delegate's start runs; what the app calls meanwhile is kept for it.
        ///
        /// ```swift
        /// Kontala.start(writeKey: "pk_live_...", endpoint: "https://konta.la/v1/events")
        /// ```
        public static func start(writeKey: String, endpoint: String, options: KontalaOptions = KontalaOptions()) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { start(writeKey: writeKey, endpoint: endpoint, options: options) }
                return
            }
            Launch.when(Launch.sharedApplication) { app in
                begin(app, writeKey: writeKey, endpoint: endpoint, options: options)
            }
        }

        private static func begin(_ app: UIApplication, writeKey: String, endpoint: String, options: KontalaOptions) {
            let platform = ApplePlatform(app: app)
            let scheduler = QueueScheduler()
            let http = SessionHttp()
            var started: Running?
            started = start(
                writeKey: writeKey,
                endpoint: endpoint,
                options: options,
                platform: platform,
                scheduler: scheduler,
                http: http,
                clock: Clock(),
                main: { f in DispatchQueue.main.async(execute: f) },
                onStop: {
                    // The observers and the hooks' watcher are the main thread's to take away.
                    DispatchQueue.main.async {
                        measures?.stop()
                        measures = nil
                        platform.fingerprinter = nil
                        platform.readier = nil
                        lifecycle?.detach()
                        lifecycle = nil
                        ScreenWatcher.current = nil
                        TapReader.current?.stopObserving()
                        TapReader.current = nil
                    }
                    scheduler.shutdown()
                    http.close()
                }
            )
            guard let r = started else { return }
            r.warn = { line in if options.debug || platform.debuggable { platform.log(line) } }
            let l = AppLifecycle(running: r, platform: platform, app: app, state: platform.initialState())
            lifecycle = l
            l.attach()
            let watcher = ScreenWatcher(signals: CoreScreenSignals(r), window: ScreenWatcher.keyWindow)
            watcher.warn = r.warn
            ScreenWatcher.current = watcher
            UIKitHooks.installed
            let m = MeasureReaders(r, options: options, watcher: watcher, lifecycle: l, platform: platform)
            measures = m
            // Every touch is read where taps, friction or scrolling are captured.
            if options.taps || options.friction || options.scroll {
                let taps = TapReader(
                    signals: CoreTapSignals(r), switches: r.core.switches, captureText: options.captureText,
                    navigationAt: { [weak watcher] in watcher?.begunAt ?? -.greatestFiniteMagnitude },
                    active: { app.applicationState == .active })
                taps.friction = m.friction
                taps.swipes = m.swipes
                taps.scroll = m.scroll
                TapReader.current = taps
                taps.observe()
                TapHooks.installed
            }
            // Started once a screen was on show already: it is read at the next frame, as the launch's.
            if ScreenWatcher.keyWindow()?.rootViewController != nil { watcher.schedule() }
        }

        /// A universal link that opened the app, or that it was sent while running, from `scene(_:continue:)`, the
        /// scene's `connectionOptions.userActivities` or SwiftUI's `.onContinueUserActivity`: the screen it opens is a
        /// `link`, as `handle(url:)` says.
        public static func handle(userActivity: NSUserActivity) {
            guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
                return
            }
            handle(url: url)
        }
    }
#endif
