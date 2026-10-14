#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit

    /// Where the app is, from UIKit's own notifications, told to the core: active is in front, inactive is still on
    /// show, as iOS draws an app's first frame while it is inactive and an app behind the app switcher or a system
    /// alert is inactive too, and background is hidden.
    ///
    /// The Flutter SDK held a navigation while the app was anything but resumed until 2026-10-08, and every iOS
    /// launch's screen view with it; inactive counting as on show is the fix this ports.
    final class AppLifecycle {
        private let running: Kontala.Running
        private let platform: ApplePlatform
        private let app: UIApplication
        private var observers: [NSObjectProtocol] = []
        private var state: AppState

        /// Told on the main thread just before the core hears the app was hidden, while what it showed is still there
        /// to read: a scroll view's last reading, what the screen showed.
        var beforeHide: [() -> Void] = []

        /// Whether the app is on show, for the thread that crashes.
        let visible: Shared<Bool>

        init(running: Kontala.Running, platform: ApplePlatform, app: UIApplication, state: AppState) {
            self.running = running
            self.platform = platform
            self.app = app
            self.state = state
            visible = Shared(state != .hidden)
        }

        /// Starts listening, on the main thread. The launch's first frame is the screen watcher's to tell, once it has
        /// read the first screen.
        func attach() {
            let center = NotificationCenter.default
            func on(_ name: Notification.Name, _ f: @escaping () -> Void) {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in f() })
            }
            on(UIApplication.didBecomeActiveNotification) { [weak self] in self?.became(.resumed) }
            on(UIApplication.willResignActiveNotification) { [weak self] in self?.became(.inactive) }
            on(UIApplication.willEnterForegroundNotification) { [weak self] in self?.became(.inactive) }
            on(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.became(.hidden) }
            on(UIDevice.orientationDidChangeNotification) { [weak self] in self?.platform.windowChanged() }
        }

        func detach() {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
        }

        private func became(_ next: AppState) {
            if next == state { return }
            state = next
            visible.value = next != .hidden
            platform.windowChanged()
            if next == .hidden {
                for f in beforeHide { f() }
                // Time until the core has heard: it asks for its own for the flush as it does.
                let task = BackgroundTask(app, "kontala.hide")
                running.post { core in
                    core.lifecycleChanged(.hidden)
                    DispatchQueue.main.async { task.end() }
                }
                return
            }
            running.post { $0.lifecycleChanged(next) }
        }
    }
#endif
