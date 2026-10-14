#if os(iOS)
    import Foundation
    import UIKit

    /// Where `Kontala.start` finds the app. SwiftUI runs a SwiftUI app's `App.init`, where the guide starts the SDK,
    /// before UIApplicationMain has made the shared application, so a start there waits for the app to finish
    /// launching, which is where an app delegate's start runs; until 2026-10-14 it returned, and the SDK captured
    /// nothing in a SwiftUI app. An app extension has no shared application, and starts nothing.
    enum Launch {
        /// The shared application, read through the runtime, where an app extension has none to give.
        static func sharedApplication() -> UIApplication? {
            UIApplication.value(forKey: "sharedApplication") as? UIApplication
        }

        /// Runs [then] with what [find] finds: at once where it finds something, and otherwise once, as the app
        /// finishes launching, which [center] tells on the main thread; in an app extension, never.
        static func when<T>(
            _ find: @escaping () -> T?, center: NotificationCenter = .default,
            isExtension: Bool = Bundle.main.bundleURL.pathExtension == "appex", _ then: @escaping (T) -> Void
        ) {
            if let found = find() {
                then(found)
                return
            }
            if isExtension { return }
            let waiting = Waiting()
            waiting.token = center.addObserver(
                forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: nil
            ) { _ in
                guard let token = waiting.token else { return }
                waiting.token = nil
                center.removeObserver(token)
                if let found = find() { then(found) }
            }
        }

        /// The observer a wait holds until the launch is told.
        private final class Waiting {
            var token: NSObjectProtocol?
        }
    }
#endif
