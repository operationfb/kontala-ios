#if os(iOS)
    import UIKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore

    /// The swizzled appearance methods tell the watcher as UIKit calls them: here an animated push, which UIKit
    /// completes with no application, from its first sign to its screen.
    final class UIKitHooksTests: XCTestCase {
        override func tearDown() {
            ScreenWatcher.current = nil
        }

        func testAnAnimatedPushIsToldFromItsFirstSignToItsScreen() {
            let rec = Recorded()
            let window = UIWindow(frame: UIScreen.main.bounds)
            let watcher = ScreenWatcher(signals: rec, window: { window })
            // What earlier tests' windows and the keyboard's own view controllers still tell the hooks, as they go,
            // is told before this watcher listens: the hooks tell whichever watcher is current, and a stray one read
            // the launch's screen before its view had loaded.
            spin(0.5)
            ScreenWatcher.current = watcher
            UIKitHooks.installed
            let nav = UINavigationController(rootViewController: ShopViewController())
            window.rootViewController = nav
            window.makeKeyAndVisible()
            spin(0.5)
            XCTAssertEqual(["begin push", "shown ShopViewController push", "firstFrame"], rec.calls)
            rec.calls.removeAll()

            nav.pushViewController(CartViewController(), animated: true)
            spin(2)
            XCTAssertEqual(["begin push", "shown CartViewController push (Cart)"], rec.calls)
            window.isHidden = true
        }
    }
#endif
