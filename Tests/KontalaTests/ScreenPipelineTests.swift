#if os(iOS)
    import UIKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// A screen whose own code declares its page type and data as it loads, as an app's `viewDidLoad` does.
    final class BasketViewController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            Kontala.pageType(.cart)
            Kontala.screenData(["items": 2])
        }
    }

    /// The screen watcher and the core together: what the collector receives for view controllers as the app moves
    /// between them, the Android SDK's `ScreenPipelineTest`.
    final class ScreenPipelineTests: XCTestCase {
        override func setUp() { Kontala.debugReset() }

        override func tearDown() { Kontala.debugReset() }

        func testALaunchFromALinkAPushAndAPopAreThreeScreenViews() {
            let s = startKontala(served: contract2())
            let window = UIWindow(frame: UIScreen.main.bounds)
            let watcher = ScreenWatcher(
                signals: CoreScreenSignals(s.running), window: { window },
                nextFrame: { DispatchQueue.main.async(execute: $0) }, inFlight: { _ in false })
            /// The frames between two steps: the watcher's read at the next one, then what it told the core.
            func frames() {
                spin()
                s.scheduler.runDue()
                s.advanceMillis(100)
            }

            // The link that opened the app, which the scene hands over before its first screen.
            Kontala.handle(url: URL(string: "kontalashop://shop/?utm_source=push&utm_campaign=autumn")!)
            let shop = ShopViewController()
            let nav = UINavigationController(rootViewController: shop)
            shop.loadViewIfNeeded()
            watcher.loaded(shop)
            window.rootViewController = nav
            window.makeKeyAndVisible()
            watcher.didAppear(shop)
            frames()
            s.advanceMillis(1000)

            // Pushed: the watcher hears of it at the basket's `viewDidLoad`, before the basket's own code runs.
            let basket = BasketViewController()
            watcher.loaded(basket)
            basket.loadViewIfNeeded()
            nav.pushViewController(basket, animated: false)
            watcher.willAppear(basket, arriving: true)
            watcher.didAppear(basket)
            frames()
            s.advanceMillis(1000)

            watcher.willDisappear(basket, leaving: true)
            nav.popViewController(animated: false)
            watcher.didDisappear(basket, leaving: true)
            watcher.willAppear(shop, arriving: false)
            watcher.didAppear(shop)
            frames()
            s.sendAll()

            let views = s.collector.named("page_view")
            XCTAssertEqual(
                [
                    [
                        "name": "ShopViewController", "query": "utm_source=push&utm_campaign=autumn",
                        "navigation": "launch",
                    ] as JSONObject,
                    ["name": "BasketViewController", "navigation": "push", "from": "ShopViewController"],
                    ["name": "ShopViewController", "navigation": "pop", "from": "BasketViewController"],
                ], views.map { $0.obj("screen")! })
            XCTAssertEqual("cart", views[1].str("page_type"), "declared in viewDidLoad, on its own screen")
            XCTAssertEqual(["items": 2] as JSONObject, views[1].obj("properties"))
            XCTAssertEqual(
                [
                    "page_view", "app_opened", "view_time", "page_speed", "page_view", "view_time", "page_speed",
                    "page_view",
                ],
                s.collector.events.map { $0.str("event")! }, "each view's time and speed are sent as it ends, under it")
            window.isHidden = true
        }
    }
#endif
