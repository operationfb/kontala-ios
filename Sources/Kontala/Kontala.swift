@_exported import KontalaCore

#if os(iOS)
    import Foundation
    import UIKit

    extension Kontala {
        private static var lifecycle: AppLifecycle?

        /// Starts capturing, as the app starts: in `App.init` or `application(_:didFinishLaunchingWithOptions:)`, on
        /// the main thread. [writeKey] is the property's public write key, and [endpoint] the Events API URL Kontala
        /// shows beside it.
        ///
        /// ```swift
        /// Kontala.start(writeKey: "pk_live_...", endpoint: "https://konta.la/v1/events")
        /// ```
        public static func start(writeKey: String, endpoint: String, options: KontalaOptions = KontalaOptions()) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { start(writeKey: writeKey, endpoint: endpoint, options: options) }
                return
            }
            let app = UIApplication.shared
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
                    // The observers are the main thread's to take away.
                    DispatchQueue.main.async {
                        lifecycle?.detach()
                        lifecycle = nil
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
        }

        /// A link that opened the app, or that it was sent while running, from `scene(_:openURLContexts:)`, the scene's
        /// `connectionOptions.urlContexts`, `application(_:open:options:)` or SwiftUI's `.onOpenURL`: the screen it
        /// opens is a `link`, with the link's query, so its campaign is on the visit.
        public static func handle(url: URL) {
            current?.post { $0.hub.linkPushed(url.absoluteString) }
        }
    }
#endif
