#if os(iOS)
    import SwiftUI
    import UIKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore

    /// What the screen watcher tells the core, written down.
    final class Recorded: ScreenSignals {
        var calls: [String] = []
        var declarations: [ScreenDeclaration?] = []
        var routes: [RouteRef] = []

        func begin(_ kind: NavigationKind) { calls.append("begin \(kind.wire)") }

        func shown(
            _ raw: String?, _ kind: NavigationKind, _ declaration: ScreenDeclaration?, _ route: RouteRef,
            _ title: String?
        ) {
            calls.append("shown \(raw ?? "nil") \(kind.wire)" + (title.map { " (\($0))" } ?? ""))
            declarations.append(declaration)
            routes.append(route)
        }

        func declared(_ route: RouteRef, _ declaration: ScreenDeclaration) {
            calls.append("declared \(declaration.name ?? "nil")")
        }

        func routeChanged() { calls.append("routeChanged") }

        func firstFrame() { calls.append("firstFrame") }
    }

    final class ShopViewController: UIViewController {}

    final class CartViewController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            navigationItem.title = "Cart"
        }
    }

    final class SearchViewController: UIViewController {}

    final class ProductViewController: UIViewController, KontalaScreen {
        var kontalaScreenName: String? { "/product/42" }
        var kontalaPageType: KontalaPageType? { .productDetail }
        var kontalaScreenProperties: [String: Any]? { ["product_id": "42"] }
    }

    /// A screen of the app's own that shows another inside it, as a container of its own does.
    final class FrameViewController: UIViewController {}

    /// Runs the main thread's run loop for [seconds], as the frames between two steps of a test, and on until all that
    /// was queued on the main thread before it has run: SwiftUI's first render of a screen can hold the main thread
    /// past a short wait, measured at 80 ms on the simulator.
    func spin(_ seconds: TimeInterval = 0.05) {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let least = Date().addingTimeInterval(seconds)
        let most = Date().addingTimeInterval(max(seconds, 10))
        while (!drained || Date() < least) && Date() < most {
            RunLoop.main.run(until: min(least, Date().addingTimeInterval(0.01)))
        }
    }

    /// The screens of view controllers as the watcher tells them, its hooks called as UIKit calls them: a test of
    /// the package runs with no application, where UIKit sends no view controller of a transition without animation
    /// its appearance, and ends no tab switch it starts, so the hooks are called here, around real hierarchies, with
    /// no transition in flight, and `UIKitHooksTests` holds the swizzled methods to calling them.
    final class ScreenWatcherTests: XCTestCase {
        private var window: UIWindow!
        private var rec: Recorded!
        private var watcher: ScreenWatcher!

        override func setUp() {
            window = UIWindow(frame: UIScreen.main.bounds)
            rec = Recorded()
            watcher = ScreenWatcher(
                signals: rec, window: { [weak self] in self?.window },
                nextFrame: { DispatchQueue.main.async(execute: $0) }, inFlight: { _ in false })
        }

        override func tearDown() {
            window.isHidden = true
            window = nil
        }

        /// Shows [root] in the window, its first screen read at the next frame.
        @discardableResult
        private func launch(_ root: UIViewController, screen: UIViewController) -> UIViewController {
            // Its view loaded first, as an app's `viewDidLoad` comes before the hook: a window lays out its root at a
            // moment of UIKit's own, which the screen's first reading can otherwise come before.
            screen.loadViewIfNeeded()
            watcher.loaded(screen)
            window.rootViewController = root
            window.makeKeyAndVisible()
            watcher.willAppear(screen, arriving: false)
            watcher.didAppear(root)
            watcher.didAppear(screen)
            spin()
            return root
        }

        private func push(_ nav: UINavigationController, _ vc: UIViewController) {
            watcher.loaded(vc)
            vc.loadViewIfNeeded()
            nav.pushViewController(vc, animated: false)
            watcher.willAppear(vc, arriving: true)
            watcher.didAppear(vc)
            spin()
        }

        private func pop(_ nav: UINavigationController) {
            guard let top = nav.topViewController else { return }
            watcher.willDisappear(top, leaving: true)
            nav.popViewController(animated: false)
            watcher.didDisappear(top, leaving: true)
            if let back = nav.topViewController {
                watcher.willAppear(back, arriving: false)
                watcher.didAppear(back)
            }
            spin()
        }

        func testAScreenIsMeasuredFromItsNavigationsFirstFrameAndNumberedWhereItsNameChanges() {
            var flying = false
            var told: [String] = []
            let w = ScreenWatcher(
                signals: rec, window: { [weak self] in self?.window },
                nextFrame: { DispatchQueue.main.async(execute: $0) }, inFlight: { _ in flying })
            w.onFirstFrame = { told.append("framed") }
            w.onScreen = { start, _, vc, renamed in
                told.append("\(type(of: vc)) \(renamed ? "renamed" : "same")\(start == nil ? " unbegun" : "")")
            }
            w.onSettled = { told.append("settled") }
            let shop = ShopViewController()
            let nav = UINavigationController(rootViewController: shop)
            shop.loadViewIfNeeded()
            w.loaded(shop)
            window.rootViewController = nav
            window.makeKeyAndVisible()
            w.didAppear(shop)
            spin()
            XCTAssertEqual(["framed", "ShopViewController renamed", "settled"], told)

            // A child loading its view inside the screen on show begins no screen.
            told.removeAll()
            let child = FrameViewController()
            shop.addChild(child)
            child.view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            shop.view.addSubview(child.view)
            child.didMove(toParent: shop)
            w.loaded(child)
            spin()
            XCTAssertEqual(["framed", "ShopViewController same", "settled"], told)

            // A transition's first frame is told before the transition ends, and its screen after it.
            told.removeAll()
            flying = true
            let cart = CartViewController()
            w.loaded(cart)
            cart.loadViewIfNeeded()
            nav.pushViewController(cart, animated: false)
            w.willAppear(cart, arriving: true)
            spin()
            XCTAssertEqual(["framed"], told)
            flying = false
            w.didAppear(cart)
            spin()
            XCTAssertEqual(["framed", "CartViewController renamed", "settled"], told)
        }

        func testTheFirstScreenIsReadAtTheFrameAfterItAppearsAndTheFirstFrameIsToldAfterIt() {
            let shop = ShopViewController()
            launch(UINavigationController(rootViewController: shop), screen: shop)
            XCTAssertEqual(["begin push", "shown ShopViewController push", "firstFrame"], rec.calls)
            XCTAssertTrue(rec.routes.last?.isOf(shop) == true)
        }

        func testAPushAndAPopAreEachAScreenWithTheTitleItShows() {
            let shop = ShopViewController()
            let nav = UINavigationController(rootViewController: shop)
            launch(nav, screen: shop)
            rec.calls.removeAll()
            push(nav, CartViewController())
            XCTAssertEqual(["begin push", "shown CartViewController push (Cart)"], rec.calls)
            rec.calls.removeAll()
            pop(nav)
            XCTAssertEqual(["begin pop", "shown ShopViewController pop"], rec.calls)
        }

        func testAScreenShownAgainWithNoNavigationIsToldNothing() {
            let shop = ShopViewController()
            launch(UINavigationController(rootViewController: shop), screen: shop)
            rec.calls.removeAll()
            watcher.didAppear(shop)
            spin()
            XCTAssertEqual([], rec.calls)
        }

        func testADialogIsNoScreenButAnAnswerToATap() {
            let shop = ShopViewController()
            launch(UINavigationController(rootViewController: shop), screen: shop)
            rec.calls.removeAll()
            let alert = UIAlertController(title: "Size", message: nil, preferredStyle: .alert)
            watcher.loaded(alert)
            watcher.willAppear(alert, arriving: true)
            watcher.didAppear(alert)
            spin()
            watcher.willDisappear(alert, leaving: true)
            watcher.didDisappear(alert, leaving: true)
            spin()
            XCTAssertEqual(["routeChanged", "routeChanged"], rec.calls)
        }

        func testAScreenDeclaresItsNamePageTypeAndData() {
            let product = ProductViewController()
            launch(UINavigationController(rootViewController: product), screen: product)
            XCTAssertEqual(["begin push", "shown /product/42 push", "firstFrame"], rec.calls)
            let d = rec.declarations.last ?? nil
            XCTAssertEqual(d?.pageType, .productDetail)
            XCTAssertEqual(d?.properties, ["product_id": "42"])
        }

        func testASwiftUIScreenIsNamedByWhatItDeclaresElseItsTitleElseNothing() {
            let nav = UINavigationController(rootViewController: ShopViewController())
            launch(nav, screen: nav.topViewController!)
            rec.calls.removeAll()

            let untitled = UIHostingController(rootView: Text("Wishlist"))
            push(nav, untitled)
            XCTAssertEqual(["begin push", "shown nil push"], rec.calls, "a hosting controller's class names nothing")
            rec.calls.removeAll()

            let titled = UIHostingController(rootView: Text("Wishlist"))
            titled.navigationItem.title = "Wishlist"
            push(nav, titled)
            XCTAssertEqual(["begin push", "shown Wishlist push (Wishlist)"], rec.calls)
            rec.calls.removeAll()

            let declared = UIHostingController(rootView: Text("Product"))
            ScreenDeclarations.set(ScreenDeclaration(name: "/product/7", pageType: .productDetail), for: declared)
            push(nav, declared)
            XCTAssertEqual(["begin push", "shown /product/7 push"], rec.calls)
        }

        func testASwiftUIScreensMarkerDeclaresItsHostingControllerAndAChangeAmendsTheScreenOnShow() {
            // Read at a real frame, as the app's watcher reads: a navigation controller can put a pushed screen's
            // view in the window only as the frame is committed, and SwiftUI's marker declares as it arrives there,
            // which a read at the main queue's next turn can come before.
            watcher = ScreenWatcher(signals: rec, window: { [weak self] in self?.window }, inFlight: { _ in false })
            let nav = UINavigationController(rootViewController: ShopViewController())
            launch(nav, screen: nav.topViewController!)
            spin(0.2)
            ScreenWatcher.current = watcher
            defer { ScreenWatcher.current = nil }
            rec.calls.removeAll()

            let host = UIHostingController(
                rootView: Text("Linen shirt").kontalaScreen("/product/42", pageType: .productDetail))
            watcher.loaded(host)
            host.loadViewIfNeeded()
            nav.pushViewController(host, animated: false)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            spin(0.2)
            watcher.didAppear(host)
            spin()
            XCTAssertEqual(["begin push", "shown /product/42 push"], rec.calls)

            ScreenDeclarations.set(ScreenDeclaration(name: "/product/42", pageType: .productList), for: host)
            XCTAssertEqual("declared /product/42", rec.calls.last)
        }

        func testATabSwitchIsATabAndTheScreenIsTheSelectedTabs() {
            let shop = ShopViewController()
            let search = SearchViewController()
            let tabs = UITabBarController()
            tabs.viewControllers = [UINavigationController(rootViewController: shop), search]
            launch(tabs, screen: shop)
            XCTAssertEqual(["begin tab", "shown ShopViewController tab", "firstFrame"], rec.calls)
            rec.calls.removeAll()

            tabs.selectedIndex = 1
            watcher.loaded(search)
            watcher.willAppear(search, arriving: false)
            watcher.didAppear(search)
            spin()
            XCTAssertEqual(["begin tab", "shown SearchViewController tab"], rec.calls)
        }

        func testAChildThatFillsItsParentIsTheScreenAndABannerIsNot() {
            let frame = FrameViewController()
            let page = CartViewController()
            frame.addChild(page)
            frame.view.addSubview(page.view)
            page.view.frame = frame.view.bounds
            page.didMove(toParent: frame)
            let banner = SearchViewController()
            frame.addChild(banner)
            frame.view.addSubview(banner.view)
            banner.view.frame = CGRect(x: 0, y: 0, width: frame.view.bounds.width, height: 60)
            banner.didMove(toParent: frame)
            launch(frame, screen: page)
            XCTAssertEqual(
                ["begin push", "shown CartViewController push (Cart)", "firstFrame"], rec.calls,
                "the banner, added last, covers too little to be the screen")
        }

        func testAViewLoadedAndNeverShownSettlesOnTheScreenOnShow() {
            let shop = ShopViewController()
            launch(UINavigationController(rootViewController: shop), screen: shop)
            rec.calls.removeAll()
            let prefetched = CartViewController()
            watcher.loaded(prefetched)
            spin()
            XCTAssertEqual(
                ["begin push", "shown ShopViewController push"], rec.calls,
                "the same screen again, which the core takes as a navigation that showed nothing new")
        }

        func testWhatIsPresentedIsTheScreenInFrontAndADialogLeavesTheOneBeneath() {
            let shop = ShopViewController()
            window.rootViewController = shop
            window.makeKeyAndVisible()
            spin()
            XCTAssertTrue(ScreenKinds.front(shop).last === shop)

            let alert = UIAlertController(title: "Size", message: nil, preferredStyle: .alert)
            XCTAssertTrue(ScreenKinds.dialog(alert))
            XCTAssertFalse(ScreenKinds.content(alert))

            let modal = CartViewController()
            modal.modalPresentationStyle = .fullScreen
            shop.present(modal, animated: false)
            spin(0.2)
            XCTAssertTrue(shop.presentedViewController === modal)
            XCTAssertTrue(ScreenKinds.front(shop).last === modal)
            XCTAssertFalse(ScreenKinds.dialog(modal))
        }

        func testWhatIsAScreenAndWhatIsNot() {
            XCTAssertTrue(ScreenKinds.content(ShopViewController()))
            XCTAssertTrue(ScreenKinds.content(UIViewController()), "a plain view controller the app filled")
            XCTAssertTrue(ScreenKinds.content(UIHostingController(rootView: Text("x"))))
            XCTAssertFalse(ScreenKinds.content(UINavigationController()))
            XCTAssertFalse(ScreenKinds.content(UITabBarController()))
            XCTAssertFalse(ScreenKinds.content(UIPageViewController()))
            XCTAssertFalse(ScreenKinds.content(UIInputViewController()), "the keyboard's are the system's")
            XCTAssertTrue(ScreenKinds.swiftUIHost(UIHostingController(rootView: Text("x"))))
            XCTAssertFalse(ScreenKinds.swiftUIHost(ShopViewController()))
            XCTAssertNil(ScreenNames.className(UIViewController()))
            XCTAssertNil(ScreenNames.className(UIHostingController(rootView: Text("x"))))
            XCTAssertEqual("ShopViewController", ScreenNames.className(ShopViewController()))
            let titled = ShopViewController()
            titled.title = "  "
            XCTAssertNil(ScreenNames.title(titled), "a blank title is none")
            titled.title = "Shop"
            XCTAssertEqual("Shop", ScreenNames.title(titled))
            titled.navigationItem.title = "Autumn sale"
            XCTAssertEqual("Autumn sale", ScreenNames.title(titled), "the navigation item's first")
        }
    }
#endif
