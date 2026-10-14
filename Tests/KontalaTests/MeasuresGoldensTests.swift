#if os(iOS)
    import UIKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// The catalogue of the measures' session: a long page with a control that answers nothing, a disabled one, a
    /// carousel and a button whose action throws, as the Android SDK's `MeasuresActivity` has.
    final class CatalogueScreen: UIViewController, KontalaScreen {
        let page = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let column = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 3900))
        let returns = UIButton(type: .system)
        let soldOut = UIButton(type: .system)
        let pay = UIButton(type: .system)
        let carousel = ShopCarousel(frame: CGRect(x: 0, y: 300, width: 402, height: 120))

        var kontalaScreenName: String? { "/catalogue" }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Catalogue"
            view.backgroundColor = .white
            page.contentInsetAdjustmentBehavior = .never
            page.contentSize = column.bounds.size
            page.addSubview(column)
            // Below the navigation bar, which the screen's view runs under, and Pay on show once the page scrolled.
            for (b, text, y) in [(returns, "Free returns", 140), (soldOut, "XL sold out", 200), (pay, "Pay", 700)]
                as [(UIButton, String, CGFloat)]
            {
                b.setTitle(text, for: .normal)
                b.frame = CGRect(x: 16, y: y, width: 200, height: 44)
                column.addSubview(b)
            }
            soldOut.isEnabled = false
            carousel.contentSize = CGSize(width: 1600, height: 120)
            column.addSubview(carousel)
            view.addSubview(page)
        }
    }

    /// A screen with nothing to scroll.
    final class StillScreen: UIViewController, KontalaScreen {
        var kontalaScreenName: String? { "/still" }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Still"
            view.backgroundColor = .white
        }
    }

    /// The measures in one visit, held to the Android SDK's golden of the same name (its `MeasuresTest`), which tells
    /// the Flutter SDK's story: the readers read UIKit's views and the core's plugins send, each step timed as
    /// Android's is, on the core's clock, and the touches' own times as their gestures take.
    final class MeasuresGoldensTests: XCTestCase {
        private var window: UIWindow!
        private var nav: UINavigationController!
        private var s: Session!
        private var watcher: ScreenWatcher!
        private var reader: TapReader!
        private var friction: FrictionReader!
        private var scroll: ScrollWatcher!
        private var speed: SpeedWatcher!
        private var crashes: Crashes!
        private var dir: String?

        override func setUp() { Kontala.debugReset() }

        override func tearDown() {
            crashes?.uninstall()
            window?.rootViewController = nil
            window?.isHidden = true
            window = nil
            Kontala.debugReset()
            if let d = dir { try? FileManager.default.removeItem(atPath: d) }
        }

        /// The core's clock, in seconds, which the readers read too.
        private var seconds: TimeInterval { Double(s.scheduler.nowMicros) / 1_000_000 }

        /// The SDK started on [dir], with the readers wired as the app's start wires them.
        private func start(_ dir: String) {
            s = startKontala(facts: testFacts(storageDir: dir), served: contract2())
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let signals = CoreMeasureSignals(s.running)
            let switches = s.core.switches
            friction = FrictionReader(
                switches: switches, debug: false, windows: { [unowned self] in [self.window] },
                now: { [unowned self] in self.seconds })
            friction.signals = signals
            s.platform.fingerprinter = { [unowned self] in self.friction.fingerprint() }
            let swipes = SwipeReader(switches: switches)
            swipes.signals = signals
            scroll = ScrollWatcher(
                switches: switches, now: { [unowned self] in self.seconds },
                after: { [unowned self] delay, f in _ = self.s.scheduler.schedule(Int64(delay * 1_000_000)) { f() } })
            scroll.signals = signals
            scroll.moved = { [unowned self] in self.friction.scrollChanged() }
            speed = SpeedWatcher(
                switches: switches, processStart: nil, countsFrames: false, now: { [unowned self] in self.seconds },
                nextFrame: { DispatchQueue.main.async(execute: $0) })
            speed.signals = signals
            friction.speed = speed
            crashes = Crashes(
                context: { [weak core = s.core] in core?.crashContext },
                lastTap: { [unowned self] in
                    self.friction.lastTap
                }, visible: { true }, now: { [unowned self] in self.seconds })
            watcher = ScreenWatcher(
                signals: CoreScreenSignals(s.running), window: { [unowned self] in self.window },
                nextFrame: { DispatchQueue.main.async(execute: $0) }, inFlight: { _ in false },
                clock: { [unowned self] in self.seconds })
            watcher.onFirstFrame = { [unowned self] in self.speed.navigationFramed() }
            watcher.onScreen = { [unowned self] start, framedAt, vc, renamed in
                if renamed { self.speed.shown(start: start, framedAt: framedAt) }
                self.scroll.shown(vc)
            }
            watcher.onSettled = { [unowned self] in self.speed.navigationSettled() }
            reader = TapReader(
                signals: CoreTapSignals(s.running), switches: switches, captureText: true,
                navigationAt: { [unowned self] in self.watcher.begunAt }, active: { true })
            reader.friction = friction
            reader.swipes = swipes
            reader.scroll = scroll
        }

        /// The main thread's work done, and what it told the core taken.
        private func settle() {
            spin()
            s.scheduler.runDue()
        }

        private func pass(_ ms: Int64) {
            s.advanceMillis(ms)
            settle()
        }

        private func sample(_ p: CGPoint, at t: TimeInterval) -> TouchSample {
            TouchSample(window: window, view: window.hitTest(p, with: nil), point: p, time: t)
        }

        private func tap(_ v: UIView) {
            let p = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            reader.began(sample(p, at: seconds))
            reader.ended(sample(p, at: seconds))
            reader.dispatched()
            settle()
        }

        /// A finger dragged from [from] by [by] over 450 ms of its own, moving what [moves] moves as it goes.
        private func drag(_ from: CGPoint, by: CGVector, moves: () -> Void) {
            let to = CGPoint(x: from.x + by.dx, y: from.y + by.dy)
            reader.began(sample(from, at: seconds))
            moves()
            reader.moved(sample(to, at: seconds + 0.2))
            reader.ended(sample(to, at: seconds + 0.45))
            reader.dispatched()
            settle()
        }

        /// The app going to the background, its readers told first, as the app's lifecycle tells them.
        private func hide() {
            friction.hiding()
            scroll.hiding()
            speed.hiding()
            s.lifecycle(.inactive)
            s.lifecycle(.hidden)
            settle()
        }

        func testAVisitThatMeetsEveryMeasure() throws {
            let d = temporaryDirectory()
            dir = d
            start(d)
            crashes.install()

            let catalogue = CatalogueScreen()
            nav = UINavigationController(rootViewController: catalogue)
            catalogue.loadViewIfNeeded()
            watcher.loaded(catalogue)
            window.rootViewController = nav
            window.makeKeyAndVisible()
            watcher.didAppear(catalogue)
            settle()
            pass(1500)

            for _ in 0..<3 {
                tap(catalogue.returns)
                pass(100)
            }
            pass(8000)
            tap(catalogue.soldOut)
            pass(1000)
            let carousel = catalogue.carousel.convert(CGPoint(x: 350, y: 60), to: nil)
            drag(carousel, by: CGVector(dx: -300, dy: 0)) { catalogue.carousel.contentOffset.x = 300 }
            pass(500)
            drag(CGPoint(x: 200, y: 800), by: CGVector(dx: 0, dy: -300)) { catalogue.page.contentOffset.y = 300 }
            pass(500)

            let still = StillScreen()
            watcher.loaded(still)
            still.loadViewIfNeeded()
            nav.pushViewController(still, animated: false)
            watcher.willAppear(still, arriving: true)
            watcher.didAppear(still)
            settle()
            pass(1500)

            hide()
            pass(5000)
            s.lifecycle(.inactive)
            s.lifecycle(.resumed)
            pass(1000)

            watcher.willDisappear(still, leaving: true)
            nav.popViewController(animated: false)
            watcher.didDisappear(still, leaving: true)
            watcher.willAppear(catalogue, arriving: false)
            watcher.didAppear(catalogue)
            settle()
            pass(1500)

            tap(catalogue.pay)
            XCTAssertTrue(
                crashes.record(
                    NSException(
                        name: .internalInconsistencyException, reason: "Payment 42 failed for anna@example.com",
                        userInfo: nil)), "written as the process ends")
            s.sendAll()
            let first = s.collector.requests
            let at = s.scheduler.nowMicros
            crashes.uninstall()
            Kontala.debugReset()

            let next = startKontala(facts: testFacts(storageDir: d), served: contract2(), start: at)
            next.advanceMillis(500)
            next.sendAll()
            next.finish()
            if let wrong = goldenMismatch(
                "measures_visit",
                "iOS's measures in one visit: a swipe across a carousel, scroll depth, a rage tap on a control that "
                    + "answers nothing, a dead tap and a disabled one, each screen's speed and time, a return to the "
                    + "app, and an exception nothing caught, written as the process ends and sent by its next launch.",
                capture: ["data_layer": "discover", "clicks": true, "scroll": true, "friction": true], refused: [],
                requests: first + next.collector.requests)
            {
                XCTFail(wrong)
            }
        }
    }
#endif
