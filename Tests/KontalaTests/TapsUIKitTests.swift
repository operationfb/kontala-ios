#if os(iOS)
    import SwiftUI
    import UIKit
    import WebKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// A card of the app's own, which the app listens for taps on.
    final class ProductCard: UIView {
        var taps = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        required init?(coder: NSCoder) { fatalError("not from a storyboard") }

        @objc private func tapped() { taps += 1 }
    }

    /// A screen of the controls a tap is read off, laid out by hand so every test knows where each is.
    final class TapsScreen: UIViewController {
        let card = ProductCard(frame: CGRect(x: 16, y: 100, width: 370, height: 120))
        let add = UIButton(type: .system)
        let name = UILabel(frame: CGRect(x: 16, y: 16, width: 200, height: 30))
        let soldOutCard = ProductCard(frame: CGRect(x: 16, y: 230, width: 370, height: 60))
        let soldOut = UIButton(type: .system)
        let soldOutAlone = UIButton(type: .system)
        let gift = UIButton(type: .system)
        let ignored = UIButton(type: .system)
        let wrap = UISwitch()
        let size = UISegmentedControl(items: ["S", "M", "L"])
        let volume = UISlider(frame: CGRect(x: 16, y: 470, width: 200, height: 30))
        let email = UITextField(frame: CGRect(x: 16, y: 510, width: 370, height: 40))
        let guide = UITextView(frame: CGRect(x: 16, y: 560, width: 370, height: 60))
        let hold = UIButton(type: .system)
        let web = WKWebView(frame: CGRect(x: 16, y: 690, width: 370, height: 80))

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            add.setTitle("Add to bag", for: .normal)
            add.frame = CGRect(x: 230, y: 70, width: 120, height: 40)
            add.accessibilityIdentifier = "add"
            add.kontalaEvent = .addToCart
            name.text = "Linen shirt"
            card.addSubview(name)
            card.addSubview(add)
            soldOut.setTitle("Sold out", for: .normal)
            soldOut.frame = CGRect(x: 230, y: 10, width: 120, height: 40)
            soldOut.isEnabled = false
            soldOutCard.addSubview(soldOut)
            soldOutAlone.setTitle("Sold out", for: .normal)
            soldOutAlone.frame = CGRect(x: 16, y: 300, width: 120, height: 40)
            soldOutAlone.isEnabled = false
            gift.setTitle("Gift card", for: .normal)
            gift.frame = CGRect(x: 150, y: 300, width: 110, height: 40)
            gift.accessibilityIdentifier = "gift"
            gift.kontalaMask = true
            ignored.setTitle("Hidden", for: .normal)
            ignored.frame = CGRect(x: 270, y: 300, width: 110, height: 40)
            ignored.kontalaIgnore = true
            wrap.frame.origin = CGPoint(x: 16, y: 360)
            wrap.accessibilityIdentifier = "wrap"
            size.frame = CGRect(x: 16, y: 410, width: 200, height: 32)
            size.selectedSegmentIndex = 1
            email.placeholder = "Email"
            email.text = "anna@example.com"
            let text = NSMutableAttributedString(string: "Read the size guide")
            text.addAttribute(
                .link, value: URL(string: "https://shop.example/sizes")!, range: NSRange(location: 9, length: 10))
            text.addAttribute(.font, value: UIFont.systemFont(ofSize: 17), range: NSRange(location: 0, length: 19))
            guide.attributedText = text
            guide.isEditable = false
            guide.isScrollEnabled = false
            hold.setTitle("Hold", for: .normal)
            hold.frame = CGRect(x: 16, y: 630, width: 120, height: 40)
            hold.addGestureRecognizer(UILongPressGestureRecognizer(target: nil, action: nil))
            for v in [card, soldOutCard, soldOutAlone, gift, ignored, wrap, size, volume, email, guide, hold, web] {
                view.addSubview(v)
            }
        }
    }

    /// A login, a field for who and one that hides its text, and its button.
    final class LoginScreen: UIViewController {
        let form = UIView(frame: CGRect(x: 0, y: 100, width: 402, height: 300))
        let user = UITextField(frame: CGRect(x: 16, y: 0, width: 370, height: 44))
        let password = UITextField(frame: CGRect(x: 16, y: 60, width: 370, height: 44))
        let logIn = UIButton(type: .system)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            user.placeholder = "Email"
            user.textContentType = .username
            user.keyboardType = .emailAddress
            user.text = "anna@example.com"
            user.returnKeyType = .next
            password.placeholder = "Password"
            password.isSecureTextEntry = true
            password.text = "hunter2"
            password.returnKeyType = .go
            logIn.setTitle("Log in", for: .normal)
            logIn.frame = CGRect(x: 16, y: 120, width: 370, height: 44)
            for v in [user, password, logIn] { form.addSubview(v) }
            view.addSubview(form)
        }
    }

    /// A search box, a button beside it, and the page under them.
    final class SearchScreen: UIViewController {
        let bar = UIView(frame: CGRect(x: 0, y: 100, width: 402, height: 60))
        let box = UISearchTextField(frame: CGRect(x: 16, y: 8, width: 300, height: 44))
        let go = UIButton(type: .system)

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            box.placeholder = "Search the shop"
            box.text = "Linen shirt"
            box.returnKeyType = .search
            go.setTitle("Go", for: .normal)
            go.accessibilityLabel = "Search"
            go.frame = CGRect(x: 320, y: 8, width: 70, height: 44)
            bar.addSubview(box)
            bar.addSubview(go)
            view.addSubview(bar)
        }
    }

    /// The presses a reader sends.
    final class RecordedTaps: TapSignals {
        var presses: [Press] = []
        func tapped(_ press: Press) { presses.append(press) }

        var elements: [JSONObject] { presses.map { $0.target.toFields().obj("element") ?? JSONObject() } }
    }

    /// Taps on an app's UIKit views: what a press resolves to, and when the reader sends it, driven by touches as
    /// UIKit would hand them over, since no public API makes a `UIEvent`.
    final class TapsUIKitTests: XCTestCase {
        private var window: UIWindow!
        private var rec: RecordedTaps!
        private var switches: Switches!
        private var reader: TapReader!
        private var navigatedAt: TimeInterval = -.greatestFiniteMagnitude
        private var focusedView: UIView?

        override func setUp() {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            rec = RecordedTaps()
            switches = Switches(now: { 0 })
            switches.taps = true
            switches.contract = 2
            reader = TapReader(
                signals: rec, switches: switches, captureText: true,
                navigationAt: { [unowned self] in self.navigatedAt }, active: { true },
                focused: { [unowned self] in self.focusedView })
        }

        override func tearDown() {
            window.isHidden = true
            window = nil
        }

        private func show<T: UIViewController>(_ vc: T) -> T {
            window.rootViewController = vc
            window.makeKeyAndVisible()
            vc.view.layoutIfNeeded()
            return vc
        }

        private func centre(_ v: UIView) -> CGPoint { v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }

        private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

        private func sample(_ p: CGPoint, at t: TimeInterval) -> TouchSample {
            TouchSample(window: window, view: window.hitTest(p, with: nil), point: p, time: t)
        }

        /// A press at [p], let go of at [up] after [held] seconds.
        private func tap(_ p: CGPoint, up: CGPoint? = nil, held: TimeInterval = 0.1) {
            let t = now()
            reader.began(sample(p, at: t))
            if let u = up { reader.moved(sample(u, at: t + held / 2)) }
            reader.ended(sample(up ?? p, at: t + held))
        }

        private func resolve(_ v: UIView) -> TapResolution {
            let p = centre(v)
            return TapResolver.resolve(
                TapResolver.chain(to: window.hitTest(p, with: nil)!), at: p, captureText: true)
        }

        func testATapIsTheControlItActedOnNamedAsTheWebNamesAnElement() {
            let s = show(TapsScreen())
            tap(centre(s.add))
            tap(centre(s.name))
            XCTAssertEqual(2, rec.presses.count)
            let add = rec.presses[0].target
            XCTAssertEqual("button", add.role)
            XCTAssertEqual("add", add.id)
            XCTAssertEqual("Add to bag", add.text)
            XCTAssertEqual("UIButton ProductCard", add.className)
            XCTAssertEqual("TapsScreen > ProductCard > UIButton#add", add.path)
            XCTAssertEqual("main", add.region)
            XCTAssertEqual(.addToCart, add.declared)
            XCTAssertEqual("touch", rec.presses[0].input)
            XCTAssertEqual(Double(centre(s.add).x), rec.presses[0].x)
            let card = rec.presses[1].target
            XCTAssertEqual(
                ["role": "button", "text": "Linen shirt", "class": "ProductCard"], rec.elements[1],
                "text on the card is the card's, the button in it left out")
            XCTAssertEqual("TapsScreen > ProductCard", card.path)
        }

        func testADisabledControlPassesThePressToTheCardAroundItAsUIKitDoesAndAloneSendsNothing() {
            let s = show(TapsScreen())
            if case .target(let r) = resolve(s.soldOut) {
                XCTAssertEqual("ProductCard", r.target.className, "the card a recognizer reads takes it")
                XCTAssertFalse(r.target.disabled)
            } else {
                XCTFail("the card")
            }
            // UIKit's hit test passes over a disabled control: the touch is the screen's behind it.
            if case .none = resolve(s.soldOutAlone) {} else { XCTFail("the screen behind the disabled button") }
            tap(centre(s.soldOutAlone))
            XCTAssertEqual([], rec.elements, "a disabled control's tap is no click")
        }

        func testAMaskedControlSendsItsRoleAloneAndAnIgnoredOneNothing() {
            let s = show(TapsScreen())
            tap(centre(s.gift))
            tap(centre(s.ignored))
            XCTAssertEqual([["role": "button"]], rec.elements)
            XCTAssertEqual("TapsScreen > UIButton", rec.presses[0].target.path, "a path of bare names")
        }

        func testAChoiceNamesNoneOfItsAnswerAndASliderIsNoTap() {
            let s = show(TapsScreen())
            if case .target(let r) = resolve(s.wrap) {
                XCTAssertEqual(["role": "switch", "class": "UISwitch"], r.target.toFields().obj("element"))
            } else {
                XCTFail("the switch")
            }
            if case .target(let r) = resolve(s.size) {
                XCTAssertEqual("radio", r.target.role)
                XCTAssertNil(r.target.text)
            } else {
                XCTFail("the segmented control")
            }
            if case .none = resolve(s.volume) {} else { XCTFail("a slider is dragged, not tapped") }
        }

        func testAFieldIsNamedByItsPlaceholderAndNeverSendsWhatItHolds() {
            let s = show(TapsScreen())
            guard case .target(let r) = resolve(s.email) else { return XCTFail("the field") }
            XCTAssertEqual("textbox", r.target.role)
            XCTAssertEqual("Email", r.target.label)
            XCTAssertNil(r.target.text)
        }

        func testALinkInTextIsALinkWithItsAddress() throws {
            let s = show(TapsScreen())
            let range = NSRange(location: 12, length: 1)
            guard let start = s.guide.position(from: s.guide.beginningOfDocument, offset: range.location),
                let end = s.guide.position(from: start, offset: 1),
                let r = s.guide.textRange(from: start, to: end)
            else { return XCTFail("the text's layout") }
            let rect = s.guide.firstRect(for: r)
            let p = s.guide.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            guard case .target(let t) = TapResolver.resolve(TapResolver.chain(to: s.guide), at: p, captureText: true)
            else { return XCTFail("a link") }
            XCTAssertEqual("link", t.target.role)
            XCTAssertEqual("https://shop.example/sizes", t.target.link)
            XCTAssertEqual("size guide", t.target.text, "the link's own text, as the web's <a> is")
        }

        /// A button as UIKit's accessibility bundle answers for one while an assistive technology is on: a label from
        /// its title and an identifier of UIKit's own, whatever the app set.
        final class AccessibleButton: UIButton {
            override var accessibilityLabel: String? {
                get { "made up" }
                set { super.accessibilityLabel = newValue }
            }

            override var accessibilityIdentifier: String? {
                get { "MadeUp" }
                set { super.accessibilityIdentifier = newValue }
            }
        }

        func testALabelAndAnIdentifierAreOnlyWhatTheAppSetNeverWhatAccessibilityMakesUp() {
            let s = show(TapsScreen())
            let made = AccessibleButton(type: .system)
            made.setTitle("Hold me", for: .normal)
            made.frame = CGRect(x: 150, y: 360, width: 110, height: 40)
            let set = AccessibleButton(type: .system)
            set.setImage(UIImage(systemName: "star"), for: .normal)
            set.accessibilityLabel = "Favourite"
            set.accessibilityIdentifier = "star"
            set.frame = CGRect(x: 270, y: 360, width: 110, height: 40)
            s.view.addSubview(made)
            s.view.addSubview(set)
            tap(centre(made))
            tap(centre(set))
            XCTAssertEqual(
                [["role": "button", "text": "Hold me", "class": "AccessibleButton"]], Array(rec.elements.prefix(1)),
                "no label or identifier the app did not set")
            XCTAssertEqual("Favourite", rec.presses.last?.target.label)
            XCTAssertEqual("star", rec.presses.last?.target.id)
        }

        func testAPressOnAWebViewIsThePagesOwn() {
            let s = show(TapsScreen())
            if case .ignored = resolve(s.web) {} else { XCTFail("the page reads its own") }
        }

        func testAPressThatMovesOffALongPressAndASecondFingerAreNoTaps() {
            let s = show(TapsScreen())
            let p = centre(s.add)
            tap(p, up: CGPoint(x: p.x, y: p.y + 200))
            tap(centre(s.hold), held: 0.8)
            let t = now()
            reader.began(sample(p, at: t))
            reader.cancel()
            reader.ended(sample(p, at: t + 0.1))
            var secondary = sample(p, at: t)
            secondary.input = "mouse"
            secondary.primary = false
            reader.began(secondary)
            reader.ended(sample(p, at: t + 0.1))
            XCTAssertEqual([], rec.elements)
        }

        func testAControlLetGoOfJustOutsideItIsStillTappedAsUIKitTracksAndACardIsNot() {
            let s = show(TapsScreen())
            let p = centre(s.add)
            tap(p, up: CGPoint(x: p.x, y: p.y + 50))
            XCTAssertEqual(1, rec.presses.count, "a button's touch up inside reaches 70 points out")
            let q = centre(s.name)
            tap(q, up: CGPoint(x: q.x + 20, y: q.y))
            XCTAssertEqual(1, rec.presses.count, "a tap recognizer's tap fails past 10 points")
        }

        func testAPressInAScrollerThatScrollsIsNoTap() {
            let s = show(TapsScreen())
            let scroller = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
            scroller.contentSize = CGSize(width: 402, height: 2000)
            let button = UIButton(type: .system)
            button.setTitle("Deep", for: .normal)
            button.frame = CGRect(x: 16, y: 16, width: 200, height: 44)
            scroller.addSubview(button)
            s.view.addSubview(scroller)
            let p = centre(button)
            tap(p, up: CGPoint(x: p.x, y: p.y + 15))
            XCTAssertEqual(0, rec.presses.count, "the scroll view took it")
            tap(p, up: CGPoint(x: p.x, y: p.y + 4))
            XCTAssertEqual(["Deep"], rec.elements.map { $0.str("text") })
        }

        func testALoginsButtonNamesWhoLogsInAndSendsItsFormWithoutTheSecret() {
            let s = show(LoginScreen())
            tap(centre(s.logIn))
            let press = rec.presses.first
            XCTAssertEqual("anna@example.com", press?.namedUser)
            XCTAssertEqual("click", press?.submits.str("trigger"))
            XCTAssertEqual(
                ["fields": ["email", "password"], "values": ["username": "anna@example.com"]],
                press?.submits.obj("form"), "the password withheld")
        }

        func testAtContract1ALoginsTapNamesWhoButSendsNoForm() {
            switches.contract = 1
            let s = show(LoginScreen())
            tap(centre(s.logIn))
            XCTAssertEqual("anna@example.com", rec.presses.first?.namedUser)
            XCTAssertEqual(JSONObject(), rec.presses.first?.submits)
        }

        func testAButtonBesideASearchBoxSendsItsTerm() {
            let s = show(SearchScreen())
            tap(centre(s.go))
            let press = rec.presses.first
            XCTAssertEqual("Search", press?.target.label)
            XCTAssertEqual("Linen shirt", press?.submits.str("search"))
        }

        func testTheKeyboardsSearchIsASubmitOfTheBoxWithItsTerm() {
            let s = show(SearchScreen())
            reader.fieldBegan(s.box)
            reader.keyDown(TapReader.returnKey)
            reader.keyUp(TapReader.returnKey)
            let submit = rec.presses.first
            XCTAssertEqual("submit", submit?.submits.str("trigger"))
            XCTAssertEqual("Linen shirt", submit?.submits.str("search"))
            XCTAssertEqual("searchbox", submit?.target.role)
            XCTAssertEqual("Search the shop", submit?.target.label)
            XCTAssertEqual("keyboard", submit?.input)
            XCTAssertNil(submit?.x)
        }

        func testEnterOnToTheNextFieldIsNoSubmitAndALoginsEnterNamesWhoLogsIn() {
            let s = show(LoginScreen())
            reader.fieldBegan(s.user)
            reader.keyDown(TapReader.returnKey)
            reader.fieldEnded(s.user)
            reader.fieldBegan(s.password)
            reader.keyUp(TapReader.returnKey)
            spin()
            XCTAssertEqual(0, rec.presses.count, "a field with a next key moves on")
            reader.keyDown(TapReader.returnKey)
            reader.keyUp(TapReader.returnKey)
            let submit = rec.presses.first
            XCTAssertEqual("submit", submit?.submits.str("trigger"))
            XCTAssertEqual("anna@example.com", submit?.namedUser)
            XCTAssertEqual("Password", submit?.target.label)
            XCTAssertNil(submit?.submits["form"], "UIKit has no form to send")
        }

        func testAFieldLettingGoOnItsOwnIsASubmitAndOneATapOrANavigationLetGoOfIsNot() {
            let s = show(SearchScreen())
            reader.fieldBegan(s.box)
            reader.fieldEnded(s.box)
            spin()
            XCTAssertEqual(["submit"], rec.presses.map { $0.submits.str("trigger") })

            reader.fieldBegan(s.box)
            tap(centre(s.view), held: 0.05)
            reader.fieldEnded(s.box)
            spin()
            XCTAssertEqual(1, rec.presses.count, "a tap at the same moment let go of it")

            navigatedAt = now()
            reader.fieldBegan(s.box)
            Thread.sleep(forTimeInterval: TapReader.sameMoment + 0.05)
            navigatedAt = now()
            reader.fieldEnded(s.box)
            spin()
            XCTAssertEqual(1, rec.presses.count, "the field went with its screen")
        }

        func testAKeyActivatesTheFocusedControl() {
            let s = show(TapsScreen())
            focusedView = s.add
            reader.keyDown(TapReader.space)
            reader.keyUp(TapReader.space)
            XCTAssertEqual("Add to bag", rec.presses.first?.target.text)
            XCTAssertEqual("keyboard", rec.presses.first?.input)
            XCTAssertNil(rec.presses.first?.x, "a key has no position")
        }

        func testNothingIsReadWhileTheCoreTakesNoTaps() {
            let s = show(TapsScreen())
            switches.taps = false
            tap(centre(s.add))
            XCTAssertEqual(0, rec.presses.count)
        }

        func testABarsButtonsAreTheHeadersAndATabBarsTheNavs() {
            let nav = UINavigationController(rootViewController: TapsScreen())
            nav.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Bag", style: .plain, target: nil, action: nil)
            let tabs = UITabBarController()
            nav.tabBarItem = UITabBarItem(title: "Shop", image: nil, tag: 0)
            let other = UIViewController()
            other.tabBarItem = UITabBarItem(title: "Account", image: nil, tag: 1)
            tabs.viewControllers = [nav, other]
            _ = show(tabs)
            spin(0.3)
            guard let bar = nav.navigationBar.subviews.flatMap(allViews).first(where: { label($0) == "Bag" }),
                let tab = tabs.tabBar.subviews.flatMap(allViews).first(where: { label($0) == "Account" })
            else { return XCTFail("the bar's and the tab bar's buttons") }
            // As UIKit labels its bars' views while an assistive technology is on.
            for v in allViews(nav.navigationBar) + allViews(tabs.tabBar) { v.accessibilityLabel = "made up" }
            guard case .target(let b) = resolve(bar), case .target(let t) = resolve(tab) else {
                return XCTFail("controls")
            }
            XCTAssertEqual("header", b.target.region)
            XCTAssertEqual("Bag", b.target.text)
            XCTAssertNil(b.target.label, "a bar's labels are UIKit's")
            XCTAssertNil(t.target.label)
            XCTAssertTrue(
                b.target.path?.hasPrefix("TapsScreen > UINavigationBar") ?? false, "the screen the bar is over")
            XCTAssertEqual("tab", t.target.role)
            XCTAssertEqual("nav", t.target.region)
            XCTAssertEqual("Account", t.target.text)
            XCTAssertTrue(t.target.path?.hasPrefix("TapsScreen > UITabBar") ?? false)
        }

        func testABarsButtonIsItsScreensButNeverSendsTheScreensFormOrNamesWhoLogsIn() {
            let login = LoginScreen()
            login.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Help", style: .plain, target: nil, action: nil)
            let nav = UINavigationController(rootViewController: login)
            _ = show(nav)
            spin(0.3)
            guard let help = nav.navigationBar.subviews.flatMap(allViews).first(where: { label($0) == "Help" })
            else { return XCTFail("the bar's button") }
            tap(centre(help))
            tap(centre(login.logIn))
            XCTAssertEqual(["Help", "Log in"], rec.elements.map { $0.str("text") })
            let bar = rec.presses[0]
            XCTAssertNil(
                bar.namedUser, "a container's view holds the bar beside the login, which is no form of the bar's")
            XCTAssertEqual(JSONObject(), bar.submits)
            XCTAssertEqual("anna@example.com", rec.presses[1].namedUser, "the screen's own button is the login's")
        }

        func testATapReachesTheCollectorAsAClickRowOfItsScreen() {
            Kontala.debugReset()
            defer { Kontala.debugReset() }
            let session = startKontala(served: contract2())
            Kontala.screen("/shop")
            session.scheduler.runDue()
            let reader = TapReader(
                signals: CoreTapSignals(session.running), switches: session.core.switches, captureText: true,
                navigationAt: { -.greatestFiniteMagnitude }, active: { true })
            let s = show(TapsScreen())
            let p = centre(s.add)
            let t = now()
            reader.began(sample(p, at: t))
            reader.ended(sample(p, at: t + 0.1))
            session.scheduler.runDue()
            session.sendAll()
            let click = session.collector.named("click").first
            XCTAssertEqual("Add to bag", click?.obj("element")?.str("text"))
            XCTAssertEqual("add_to_cart", click?.str("click_type"))
            XCTAssertEqual("TapsScreen > ProductCard > UIButton#add", click?.str("path"))
            XCTAssertNotNil(click?["x"])
        }

        private func allViews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(allViews) }

        private func label(_ v: UIView) -> String? { (v as? UILabel)?.text }

        func testASwiftUIControlIsReadOffItsMarkAndAnUnmarkedOneIsNone() {
            let host = UIHostingController(
                rootView: VStack(spacing: 40) {
                    Button("Add to bag") {}.kontalaEvent(.addToCart, label: "Add to bag")
                    Button("Plain") {}
                    Button("Secret") {}.kontalaIgnore()
                }.frame(maxWidth: .infinity, maxHeight: .infinity))
            _ = show(host)
            spin(0.3)
            let marks = allViews(host.view).compactMap { $0 as? TapMarkView }
            guard let event = marks.first(where: { if case .event = $0.kind { return true } else { return false } }),
                let secret = marks.first(where: { $0.kind == .ignore })
            else { return XCTFail("the marks") }
            let p = centre(event)
            guard
                case .target(let r) = TapResolver.resolve(
                    TapResolver.chain(to: window.hitTest(p, with: nil)!), at: p, captureText: true)
            else { return XCTFail("the marked button") }
            XCTAssertEqual(["role": "button", "label": "Add to bag"], r.target.toFields().obj("element"))
            XCTAssertEqual(.addToCart, r.target.declared)
            XCTAssertNil(r.target.path, "a hosting controller is no class of the app's to name")
            let plain = CGPoint(x: p.x, y: (p.y + centre(secret).y) / 2)
            if case .target = TapResolver.resolve(
                TapResolver.chain(to: window.hitTest(plain, with: nil)!), at: plain, captureText: true)
            {
                XCTFail("an unmarked SwiftUI control names nothing")
            }
            let q = centre(secret)
            if case .ignored = TapResolver.resolve(
                TapResolver.chain(to: window.hitTest(q, with: nil)!), at: q, captureText: true)
            {
            } else {
                XCTFail("ignored")
            }
        }

        /// SwiftUI's fields, as a hosting controller shows them: a `TextField` is a UITextField, whose placeholder
        /// SwiftUI always sets, and to which it hands an identifier and a label only while accessibility is on.
        @available(iOS 14, *)
        struct SwiftUIFields: View {
            @State var query = "linen"
            @State var note = ""

            var body: some View {
                VStack(spacing: 40) {
                    TextField("Search", text: $query).accessibilityIdentifier("q")
                    TextField("Note", text: $note).kontalaEvent(id: "note-box", label: "Delivery note")
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        /// A SwiftUI form whose card field the app masks and whose newsletter switch it ignores, as the demo shop's
        /// checkout masks its card number.
        struct SwiftUIPayment: View {
            @State var name = "Anna"
            @State var card = "4242424242424242"
            @State var news = true

            var body: some View {
                VStack(spacing: 40) {
                    TextField("Full name", text: $name)
                    TextField("Card number", text: $card).kontalaMask()
                    Toggle("News", isOn: $news).kontalaIgnore()
                    Button("Pay") {}.kontalaEvent(.purchase, id: "pay")
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        func testASwiftUIFieldUnderAMaskOrAnIgnoreMarkIsNeverReadIntoItsForm() {
            let host = UIHostingController(rootView: SwiftUIPayment())
            _ = show(host)
            spin(0.3)
            let marks = allViews(host.view).compactMap { $0 as? TapMarkView }
            guard let pay = marks.first(where: { if case .event = $0.kind { return true } else { return false } })
            else { return XCTFail("the pay button's mark") }
            XCTAssertEqual(1, allViews(host.view).compactMap { $0 as? UISwitch }.count, "SwiftUI's toggle is a switch")
            tap(centre(pay))
            guard let press = rec.presses.last else { return XCTFail("the pay button's tap") }
            XCTAssertEqual(.purchase, press.target.declared)
            XCTAssertEqual(
                ["full_name": "Anna"], press.submits.obj("form")?.obj("values"),
                "the masked card's number and the ignored switch are never read")
            XCTAssertFalse(
                press.submits.obj("form")?.list("fields")?.contains(.string("card")) ?? false,
                "nor is what the masked field is")
        }

        func testASwiftUIFieldIsNamedByItsMarkOrPlaceholderNeverByWhatSwiftUIHandsIt() throws {
            guard #available(iOS 14, *) else { throw XCTSkip("SwiftUI's identifiers are iOS 14's") }
            let host = UIHostingController(rootView: SwiftUIFields())
            _ = show(host)
            spin(0.3)
            let fields = allViews(host.view).compactMap { $0 as? UITextField }
            guard fields.count == 2 else { return XCTFail("SwiftUI's two fields, \(fields.count)") }
            for f in fields {
                // As SwiftUI hands them over once an assistive technology has read the screen.
                f.accessibilityIdentifier = "made-up"
                f.accessibilityLabel = "made up"
            }
            let byPlaceholder = fields.first { $0.placeholder == "Search" }!
            let marked = fields.first { $0.placeholder == "Note" }!
            guard case .target(let search) = resolve(byPlaceholder), case .target(let note) = resolve(marked) else {
                return XCTFail("SwiftUI's fields")
            }
            XCTAssertNil(search.target.id)
            XCTAssertEqual("Search", search.target.label)
            XCTAssertEqual("UITextField", search.target.path)
            XCTAssertEqual("note-box", note.target.id)
            XCTAssertEqual("Delivery note", note.target.label)
            XCTAssertNil(TapResolver.fieldInfo(byPlaceholder).name, "no name for its form's values either")
        }
    }
#endif
