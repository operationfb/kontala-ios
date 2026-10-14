#if os(iOS)
    import UIKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// The shop's home: its product's card.
    final class ShopHomeScreen: UIViewController, KontalaScreen {
        let card = ProductCard(frame: CGRect(x: 16, y: 120, width: 370, height: 120))

        var kontalaScreenName: String? { "/" }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Shop"
            view.backgroundColor = .white
            let name = UILabel(frame: CGRect(x: 16, y: 40, width: 300, height: 40))
            name.text = "Linen shirt"
            card.addSubview(name)
            view.addSubview(card)
        }
    }

    /// A product: its page type and data, a declared add to cart, a size guide that opens over it, and a login.
    final class ShopProductScreen: UIViewController, KontalaScreen {
        let add = UIButton(type: .system)
        let sizes = UIButton(type: .system)
        let guide = UIView(frame: CGRect(x: 40, y: 300, width: 320, height: 200))
        let close = UIButton(type: .system)
        let email = UITextField(frame: CGRect(x: 16, y: 20, width: 370, height: 44))
        let password = UITextField(frame: CGRect(x: 16, y: 74, width: 370, height: 44))
        let signIn = UIButton(type: .system)

        var kontalaScreenName: String? { "/product/42" }
        var kontalaPageType: KontalaPageType? { .productDetail }
        var kontalaScreenProperties: [String: Any]? {
            ["product": ["id": "42", "price": 79.0, "tags": ["linen", "summer"]] as [String: Any]]
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Linen shirt"
            view.backgroundColor = .white
            add.setTitle("Add to cart", for: .normal)
            add.frame = CGRect(x: 16, y: 120, width: 200, height: 44)
            add.kontalaEvent = .addToCart
            sizes.setTitle("Sizes", for: .normal)
            sizes.frame = CGRect(x: 16, y: 180, width: 200, height: 44)
            guide.backgroundColor = .lightGray
            guide.isHidden = true
            close.setTitle("Close", for: .normal)
            close.frame = CGRect(x: 100, y: 140, width: 120, height: 44)
            guide.addSubview(close)
            email.placeholder = "Email"
            email.textContentType = .emailAddress
            email.keyboardType = .emailAddress
            password.placeholder = "Password"
            password.isSecureTextEntry = true
            signIn.setTitle("Sign in", for: .normal)
            signIn.frame = CGRect(x: 16, y: 130, width: 370, height: 44)
            signIn.kontalaEvent = .login
            let login = UIView(frame: CGRect(x: 0, y: 540, width: 402, height: 200))
            for v in [email, password, signIn] { login.addSubview(v) }
            for v in [add, sizes, login, guide] { view.addSubview(v) }
        }
    }

    /// A search page: a box the keyboard's search key submits.
    final class ShopSearchScreen: UIViewController, KontalaScreen {
        let box = UISearchTextField(frame: CGRect(x: 16, y: 120, width: 370, height: 44))

        var kontalaScreenName: String? { "/search" }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Search"
            view.backgroundColor = .white
            box.placeholder = "Search the shop"
            box.returnKeyType = .search
            view.addSubview(box)
        }
    }

    /// Sessions through an app's view controllers, its taps and its forms, held to the Flutter SDK's goldens of the
    /// same names (sdk/flutter/kontala_flutter/test/goldens_test.dart), which are the reference, as the Android SDK's
    /// `ShopGoldensTest` is. Each is timed as the Flutter session is, on the core's clock; the main thread's runs
    /// apart from it, and its signals reach the core as each step ends.
    final class ShopGoldensTests: XCTestCase {
        private var window: UIWindow!
        private var nav: UINavigationController!
        private var s: Session!
        private var watcher: ScreenWatcher!
        private var reader: TapReader!

        override func setUp() { Kontala.debugReset() }

        override func tearDown() {
            window?.isHidden = true
            window = nil
            Kontala.debugReset()
        }

        /// Runs [script] as a session with the screen watcher and the tap reader wired to the core, and holds what it
        /// sent to its golden.
        private func golden(
            _ name: String, _ description: String, options: KontalaOptions = KontalaOptions(),
            served: JSONObject? = nil, capture: JSONObject = ["data_layer": "discover", "clicks": true],
            _ script: () -> Void
        ) {
            s = startKontala(options, served: served)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            watcher = ScreenWatcher(
                signals: CoreScreenSignals(s.running), window: { [unowned self] in self.window },
                nextFrame: { DispatchQueue.main.async(execute: $0) }, inFlight: { _ in false })
            reader = TapReader(
                signals: CoreTapSignals(s.running), switches: s.core.switches, captureText: true,
                navigationAt: { [unowned self] in self.watcher.begunAt }, active: { true })
            script()
            s.sendAll()
            s.finish()
            if let wrong = goldenMismatch(
                name, description, capture: capture, refused: [], requests: s.collector.requests)
            {
                XCTFail(wrong)
            }
        }

        /// The main thread's work done, and what it told the core taken.
        private func settle() {
            spin()
            s.scheduler.runDue()
        }

        private func launch(_ home: ShopHomeScreen) {
            nav = UINavigationController(rootViewController: home)
            // Its view loaded first, as an app's `viewDidLoad` comes before the hook: a window lays out its root at a
            // moment of UIKit's own, which the screen's first reading can otherwise come before, with no title.
            home.loadViewIfNeeded()
            watcher.loaded(home)
            window.rootViewController = nav
            window.makeKeyAndVisible()
            watcher.didAppear(home)
            settle()
        }

        private func push(_ vc: UIViewController, from: UIViewController) {
            watcher.loaded(vc)
            vc.loadViewIfNeeded()
            nav.pushViewController(vc, animated: false)
            watcher.willAppear(vc, arriving: true)
            watcher.didAppear(vc)
            settle()
        }

        private func tap(_ v: UIView) {
            let p = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            let t = ProcessInfo.processInfo.systemUptime
            reader.began(TouchSample(window: window, view: window.hitTest(p, with: nil), point: p, time: t))
            reader.ended(TouchSample(window: window, view: window.hitTest(p, with: nil), point: p, time: t + 0.05))
            settle()
        }

        func testAVisitThroughAShop() {
            golden(
                "shop_visit",
                "A launch from a deep link with UTM tags, a product opened from its card, its page type and "
                    + "properties, a declared add to cart, a dialog, a login naming its user, a custom event, identify, "
                    + "and the app going to the background."
            ) {
                // The link that opened the app, which the scene hands over before its first screen.
                Kontala.handle(url: URL(string: "kontalashop://shop/?utm_source=push&utm_campaign=autumn")!)
                let home = ShopHomeScreen()
                launch(home)
                s.advanceMillis(1000)
                tap(home.card)
                let p = ShopProductScreen()
                push(p, from: home)
                s.advanceMillis(1000)
                tap(p.add)
                s.advanceMillis(600)
                tap(p.sizes)
                p.guide.isHidden = false
                s.advanceMillis(1000)
                tap(p.close)
                p.guide.isHidden = true
                s.advanceMillis(1000)
                p.email.text = "anna@example.com"
                p.password.text = "not sent"
                tap(p.signIn)
                s.advanceMillis(600)
                Kontala.identify(user: "customer-42", org: "acme", traits: ["plan": "pro"])
                Kontala.track(
                    "wishlisted",
                    properties: [
                        "product_id": "42",
                        "at": Date(timeIntervalSince1970: Double(goldenStartMicros / 1000 + 58_000) / 1000),
                        "sizes": ["M", "L"],
                    ])
                s.scheduler.runDue()
                s.advanceMillis(2000)
                s.lifecycle(.hidden)
            }
        }

        func testAVisitWithALoginAndASearch() {
            golden(
                "forms_visit",
                "A region on contract 2, the app capturing no scrolling or friction: screens with their titles, how "
                    + "each was reached and the screen before, a login form's values and the user it names, and a "
                    + "search submitted from the keyboard with its term: what every app SDK sends for the same taps.",
                options: KontalaOptions(scroll: false, friction: false), served: contract2(),
                capture: ["data_layer": "discover", "clicks": true, "scroll": true, "friction": true]
            ) {
                let home = ShopHomeScreen()
                launch(home)
                s.advanceMillis(1000)
                tap(home.card)
                let p = ShopProductScreen()
                push(p, from: home)
                s.advanceMillis(1000)
                p.email.text = "anna@example.com"
                p.password.text = "not sent"
                s.advanceMillis(600)
                tap(p.signIn)
                s.advanceMillis(2000)
                let search = ShopSearchScreen()
                push(search, from: p)
                s.advanceMillis(1000)
                reader.fieldBegan(search.box)
                search.box.text = "linen"
                s.advanceMillis(1000)
                reader.keyDown(TapReader.returnKey)
                reader.keyUp(TapReader.returnKey)
                settle()
                s.advanceMillis(1000)
                s.lifecycle(.hidden)
            }
        }
    }
#endif
