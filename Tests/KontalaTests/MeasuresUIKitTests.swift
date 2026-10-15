#if os(iOS)
    import UIKit
    import WebKit
    import XCTest

    @testable import Kontala
    @testable import KontalaCore
    import KontalaTestSupport

    /// A carousel of the app's own, which scrolls across.
    final class ShopCarousel: UIScrollView {}

    /// A card the app's own code drags across, as a swipe to dismiss does.
    final class DismissCard: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        }

        required init?(coder: NSCoder) { fatalError("not from a storyboard") }

        @objc private func dragged(_ g: UIPanGestureRecognizer) {
            transform = CGAffineTransform(translationX: g.translation(in: superview).x, y: 0)
        }
    }

    /// A long page of what the measures read: a control that answers nothing, one that answers, a disabled one, a
    /// carousel, a card the app drags, a field, selectable text, a slider and a web view.
    final class MeasuresScreen: UIViewController {
        let page = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let column = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 3900))
        let returns = UIButton(type: .system)
        let bag = UIButton(type: .system)
        let soldOut = UIButton(type: .system)
        let pay = UIButton(type: .system)
        let carousel = ShopCarousel(frame: CGRect(x: 0, y: 300, width: 402, height: 120))
        let card = DismissCard(frame: CGRect(x: 16, y: 440, width: 370, height: 80))
        let notes = UITextField(frame: CGRect(x: 16, y: 540, width: 370, height: 40))
        let terms = UITextView(frame: CGRect(x: 16, y: 600, width: 370, height: 60))
        let volume = UISlider(frame: CGRect(x: 40, y: 680, width: 320, height: 30))
        let web = WKWebView(frame: CGRect(x: 16, y: 730, width: 370, height: 120))

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .white
            page.contentInsetAdjustmentBehavior = .never
            page.contentSize = column.bounds.size
            page.addSubview(column)
            for (b, title, y) in [
                (returns, "Free returns", 40), (bag, "Add to bag", 100), (soldOut, "XL sold out", 160),
                (pay, "Pay", 220),
            ] as [(UIButton, String, CGFloat)] {
                b.setTitle(title, for: .normal)
                b.frame = CGRect(x: 16, y: y, width: 200, height: 44)
                column.addSubview(b)
            }
            soldOut.isEnabled = false
            bag.addTarget(self, action: #selector(added), for: .touchUpInside)
            carousel.contentSize = CGSize(width: 1600, height: 120)
            notes.placeholder = "Notes"
            terms.text = "Returns are free within 30 days."
            terms.isEditable = false
            for v in [carousel, card, notes, terms, volume, web] as [UIView] { column.addSubview(v) }
            view.addSubview(page)
        }

        @objc private func added() { bag.setTitle("Added", for: .normal) }
    }

    /// What the measures' readers tell.
    final class RecordedMeasures: MeasureSignals {
        var presses: [FrictionPress] = []
        var answers = 0
        var focus: [Bool] = []
        var prints: [Int64?] = []
        var readings: [Reading] = []
        var swipes: [Swipe] = []
        var numbered: [Int] = []
        var speed: [SpeedSignal] = []

        func pressed(_ press: FrictionPress) { presses.append(press) }
        func answered() { answers += 1 }
        func windowFocus(_ focused: Bool) { focus.append(focused) }
        func hiding(_ print: Int64?) { prints.append(print) }
        func scrolled(_ reading: Reading) { readings.append(reading) }
        func swiped(_ swipe: Swipe) { swipes.append(swipe) }
        func screenNumbered(_ screen: Int) { numbered.append(screen) }
        func measured(_ signal: SpeedSignal) { speed.append(signal) }
    }

    /// The measures' readers on an app's views, driven by touches as UIKit would hand them over and on clocks of the
    /// test's own: friction's taps and what answers them, the fingerprint, swipes, the screen's scroll view, speed's
    /// frames and taps, and an exception nothing caught.
    final class MeasuresUIKitTests: XCTestCase {
        private var window: UIWindow!
        private var screen: MeasuresScreen!
        private var rec: RecordedMeasures!
        private var switches: Switches!
        private var reader: TapReader!
        private var friction: FrictionReader!
        private var swipes: SwipeReader!
        private var clock: TimeInterval = 1000
        private var frames: [() -> Void] = []
        private var timers: [(at: TimeInterval, f: () -> Void)] = []

        private let served = contract2()

        override func setUp() {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            screen = MeasuresScreen()
            window.rootViewController = screen
            window.makeKeyAndVisible()
            screen.view.layoutIfNeeded()
            rec = RecordedMeasures()
            switches = Switches(now: { 0 })
            switches.contract = 2
            switches.taps = true
            switches.friction = FrictionRules.parse(served["friction"])
            switches.scroll = ScrollRules.parse(served["scroll"])
            friction = FrictionReader(
                switches: switches, debug: false, windows: { [unowned self] in [self.window] },
                now: { [unowned self] in self.clock })
            friction.signals = rec
            swipes = SwipeReader(switches: switches)
            swipes.signals = rec
            reader = TapReader(
                signals: RecordedTaps(), switches: switches, captureText: true, navigationAt: { -1 }, active: { true })
            reader.friction = friction
            reader.swipes = swipes
        }

        override func tearDown() {
            window.rootViewController = nil
            window.isHidden = true
            window = nil
        }

        private func centre(_ v: UIView) -> CGPoint { v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }

        private func sample(_ p: CGPoint, at t: TimeInterval) -> TouchSample {
            TouchSample(window: window, view: window.hitTest(p, with: nil), point: p, time: t)
        }

        /// A tap at [p], let go of after [held] seconds, and delivered.
        private func tap(_ p: CGPoint, held: TimeInterval = 0.1, moved: CGPoint? = nil) {
            reader.began(sample(p, at: clock))
            if let m = moved { reader.moved(sample(m, at: clock + held / 2)) }
            clock += held
            reader.ended(sample(moved ?? p, at: clock))
            reader.dispatched()
        }

        /// A finger dragged from [from] by [by] over [seconds], with [during] run as it moves, as the views it moves
        /// would.
        private func drag(_ from: CGPoint, by: CGVector, seconds: TimeInterval = 0.45, during: () -> Void = {}) {
            reader.began(sample(from, at: clock))
            during()
            let to = CGPoint(x: from.x + by.dx, y: from.y + by.dy)
            reader.moved(sample(to, at: clock + seconds / 2))
            clock += seconds
            reader.ended(sample(to, at: clock))
            reader.dispatched()
        }

        // Friction's taps.

        func testATapOnAControlIsAPressWithWhatTheAppShowedAndOneOnNothingDescribesWhatWasThere() throws {
            tap(centre(screen.returns))
            let p = try XCTUnwrap(rec.presses.first)
            XCTAssertEqual("button", p.target?.role)
            XCTAssertEqual("Free returns", p.hit.text)
            XCTAssertNotNil(p.fingerprint, "a dead tap's candidate")
            XCTAssertFalse(p.excluded)
            XCTAssertEqual(Double(centre(screen.returns).x), p.x)
            XCTAssertEqual("touch", p.input)

            clock += 5
            tap(CGPoint(x: 300, y: 270))
            let bare = try XCTUnwrap(rec.presses.last)
            XCTAssertNil(bare.target)
            XCTAssertEqual("other", bare.hit.role)
            XCTAssertNil(bare.hit.text)
            XCTAssertNotNil(bare.fingerprint, "a tap that begins a burst")
        }

        func testADisabledControlIsThePressesTargetAndAFieldOrSelectableTextIsNeverARageTap() throws {
            tap(centre(screen.soldOut))
            XCTAssertEqual(true, rec.presses.last?.target?.disabled)
            XCTAssertEqual("XL sold out", rec.presses.last?.target?.text)
            clock += 5
            tap(centre(screen.notes))
            XCTAssertEqual(true, rec.presses.last?.excluded)
            clock += 5
            tap(centre(screen.terms))
            XCTAssertEqual(true, rec.presses.last?.excluded)
        }

        func testAHoldADragAWebViewAndAnIgnoredViewAreNoPress() {
            tap(centre(screen.returns), held: 0.6)
            tap(centre(screen.returns), moved: CGPoint(x: centre(screen.returns).x + 40, y: centre(screen.returns).y))
            tap(centre(screen.web))
            screen.pay.kontalaIgnore = true
            tap(centre(screen.pay))
            XCTAssertEqual(0, rec.presses.count)
        }

        func testATapContinuingABurstTakesNoFingerprintUnlessItIsACandidate() {
            let p = CGPoint(x: 300, y: 270)
            tap(p)
            clock += 0.1
            tap(CGPoint(x: p.x + 5, y: p.y))
            XCTAssertNotNil(rec.presses[0].fingerprint)
            XCTAssertNil(rec.presses[1].fingerprint, "what the burst's first tap read stands")
            clock += 0.1
            tap(centre(screen.returns))
            XCTAssertNotNil(rec.presses[2].fingerprint, "far from the last, and a candidate")
        }

        func testTheLastTapIsTheOneStillDownElseTheLastFinished() {
            XCTAssertNil(friction.lastTap)
            tap(centre(screen.pay))
            XCTAssertEqual("Pay", friction.lastTap?.fields.obj("element")?.str("text"))
            reader.began(sample(centre(screen.returns), at: clock))
            XCTAssertEqual("Free returns", friction.lastTap?.fields.obj("element")?.str("text"))
            XCTAssertNil(friction.lastTap?.fields["click_type"])
        }

        func testWhatAnswersATapAndWhatDoesNot() {
            friction.observe()
            defer { friction.stopObserving() }
            // A field the press itself began editing is the press's.
            reader.began(sample(centre(screen.notes), at: clock))
            friction.fieldBegan()
            XCTAssertEqual(0, rec.answers)
            reader.ended(sample(centre(screen.notes), at: clock + 0.1))
            reader.dispatched()
            spin()
            friction.fieldBegan()
            XCTAssertEqual(1, rec.answers, "from the next turn on, it answers")
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            XCTAssertEqual(2, rec.answers)
            friction.scrollChanged()
            friction.scrollChanged()
            XCTAssertEqual(3, rec.answers, "a scroll is told at most every 100 ms")
            clock += 0.2
            friction.scrollChanged()
            XCTAssertEqual(4, rec.answers)
            let other = UIWindow(frame: window.frame)
            other.makeKeyAndVisible()
            window.makeKey()
            XCTAssertEqual([false, true], Array(rec.focus.suffix(2)), "another window took the key and gave it back")
            other.isHidden = true
        }

        // The fingerprint.

        func testTheFingerprintChangesWithWhatTheAppShowsAndNeverWithAPressOrWhatIsTyped() {
            let print = { Fingerprints.of([self.window], debug: false) }
            let a = print()
            XCTAssertNotNil(a)
            XCTAssertEqual(a, print())
            screen.bag.isHighlighted = true
            screen.bag.layoutIfNeeded()
            XCTAssertEqual(a, print(), "a press's highlight is no answer")
            screen.bag.isHighlighted = false
            screen.notes.text = "a gift"
            screen.notes.layoutIfNeeded()
            XCTAssertEqual(a, print(), "what is typed is no answer")
            screen.bag.setTitle("Added", for: .normal)
            screen.bag.layoutIfNeeded()
            let b = print()
            XCTAssertNotEqual(a, b, "a control's text that changed is")
            screen.carousel.contentOffset.x = 100
            XCTAssertNotEqual(b, print(), "and so is a scroll")
        }

        func testAFingerprintThatRunsOutOfItsBudgetSaysNothing() {
            let crowd = UIView(frame: screen.view.bounds)
            for _ in 0...Fingerprints.maxNodes {
                crowd.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
            screen.view.addSubview(crowd)
            XCTAssertNil(Fingerprints.of([window], debug: false))
        }

        // Swipes.

        func testASwipeAcrossACarouselIsScrolledAndOneDownThePageIsScrolling() throws {
            drag(CGPoint(x: 350, y: 360), by: CGVector(dx: -300, dy: 0)) { screen.carousel.contentOffset.x = 300 }
            let s = try XCTUnwrap(rec.swipes.first)
            XCTAssertEqual("left", s.direction)
            XCTAssertEqual("scrolled", s.effect)
            XCTAssertEqual(300, s.distance)
            XCTAssertEqual(450, s.durationMs)
            XCTAssertEqual("other", s.target.role)
            XCTAssertEqual("ShopCarousel", s.target.className)
            XCTAssertEqual(350, s.x)

            drag(CGPoint(x: 200, y: 800), by: CGVector(dx: 0, dy: -300)) { screen.page.contentOffset.y = 300 }
            XCTAssertEqual(1, rec.swipes.count, "a page scrolled down is depth's")
        }

        func testASwipeTheAppsOwnCodeTookIsScriptAndOneNothingTookIsNone() throws {
            drag(centre(screen.card), by: CGVector(dx: -200, dy: 0)) {
                screen.card.transform = CGAffineTransform(translationX: -200, y: 0)
            }
            XCTAssertEqual("script", rec.swipes.last?.effect)
            XCTAssertEqual("DismissCard", rec.swipes.last?.target.className)
            screen.card.transform = .identity
            drag(CGPoint(x: 300, y: 270), by: CGVector(dx: 200, dy: 0))
            XCTAssertEqual("none", rec.swipes.last?.effect)
            XCTAssertEqual("right", rec.swipes.last?.direction)
            XCTAssertEqual(2, rec.swipes.count)
        }

        func testNoSwipeFromAnEdgeOnASliderInAWebViewOrTooShortOrTooSlow() {
            drag(CGPoint(x: 10, y: 360), by: CGVector(dx: 300, dy: 0))
            drag(centre(screen.volume), by: CGVector(dx: 120, dy: 0))
            drag(centre(screen.web), by: CGVector(dx: -200, dy: 0))
            drag(CGPoint(x: 300, y: 270), by: CGVector(dx: -40, dy: 0))
            drag(CGPoint(x: 300, y: 270), by: CGVector(dx: -200, dy: 0), seconds: 1.5)
            drag(CGPoint(x: 300, y: 270), by: CGVector(dx: -100, dy: 90))
            XCTAssertEqual(0, rec.swipes.count)
        }

        // The screen's scroll view.

        private func watcher() -> ScrollWatcher {
            let w = ScrollWatcher(
                switches: switches, now: { [unowned self] in self.clock },
                after: { [unowned self] delay, f in self.timers.append((self.clock + delay, f)) })
            w.signals = rec
            return w
        }

        /// Runs the watcher's timers due by now.
        private func runTimers() {
            let due = timers.filter { $0.at <= clock }
            timers.removeAll { $0.at <= clock }
            for t in due { t.f() }
        }

        func testAScreensScrollViewIsReadOnceItSettlesAsItScrollsAndAsTheAppIsHidden() {
            let w = watcher()
            w.shown(screen)
            XCTAssertEqual([], rec.readings)
            clock += 1
            runTimers()
            XCTAssertEqual([Reading(874, 3900, 874)], rec.readings, "the page, never the carousel or the web view's")
            clock += 1
            screen.page.contentOffset.y = 500
            XCTAssertEqual(Reading(1374, 3900, 874), rec.readings.last)
            screen.page.contentOffset.y = 600
            XCTAssertEqual(2, rec.readings.count, "within the throttle")
            clock += 0.1
            runTimers()
            XCTAssertEqual(Reading(1474, 3900, 874), rec.readings.last)
            screen.page.contentOffset.y = 700
            w.hiding()
            XCTAssertEqual(Reading(1574, 3900, 874), rec.readings.last)
        }

        func testInsetsAreLeftOutAndContentShorterThanTheScreenIsReadToItsEnd() {
            screen.page.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 34, right: 0)
            screen.page.contentOffset.y = -100
            XCTAssertEqual(Reading(740, 3900, 740), ScrollWatcher.reading(screen.page), "at its top, a screenful")
            screen.page.contentSize.height = 300
            XCTAssertEqual(Reading(740, 740, 740), ScrollWatcher.reading(screen.page))
        }

        func testOnlyAScrollViewDownMostOfTheWindowIsTheScreensAndAWebViewsNever() {
            let narrow = UIScrollView(frame: CGRect(x: 0, y: 0, width: 150, height: 800))
            narrow.contentSize = CGSize(width: 150, height: 2000)
            XCTAssertNil(ScrollWatcher.covering(narrow, window.bounds.size), "less than half the window across")
            XCTAssertFalse(ScrollWatcher.vertical(screen.carousel), "a carousel scrolls across")
            XCTAssertTrue(ScrollWatcher.vertical(screen.page))
            // A web view larger than the page, whose own scroll view scrolls down.
            screen.page.frame.size.height = 600
            screen.web.frame = screen.view.bounds
            screen.web.scrollView.contentSize = CGSize(width: 402, height: 5000)
            screen.web.scrollView.alwaysBounceVertical = true
            screen.view.addSubview(screen.web)
            XCTAssertTrue(ScrollWatcher.vertical(screen.web.scrollView))
            XCTAssertTrue(
                ScrollWatcher.find(in: screen.view, window.bounds.size) === screen.page, "never the web view's")
            let w = watcher()
            reader.scroll = w
            w.shown(screen)
            reader.began(sample(CGPoint(x: 200, y: 700), at: clock))
            reader.cancel()
            clock += 1
            runTimers()
            XCTAssertEqual([Reading(600, 3900, 600)], rec.readings, "the page's, under a finger on the web view too")
        }

        func testAFingerOnALargerScrollViewMakesItTheScreens() {
            let w = watcher()
            reader.scroll = w
            w.shown(screen)
            clock += 1
            runTimers()
            let sheet = UIScrollView(frame: screen.view.bounds)
            sheet.contentInsetAdjustmentBehavior = .never
            sheet.contentSize = CGSize(width: 402, height: 2000)
            screen.view.addSubview(sheet)
            reader.began(sample(CGPoint(x: 200, y: 400), at: clock))
            reader.cancel()
            clock += 0.2
            sheet.contentOffset.y = 100
            XCTAssertEqual([Reading(874, 3900, 874), Reading(974, 2000, 874)], rec.readings)
        }

        // Speed.

        private func speed(processStart: TimeInterval? = 990) -> SpeedWatcher {
            let s = SpeedWatcher(
                switches: switches, processStart: processStart, countsFrames: false,
                now: { [unowned self] in self.clock }, nextFrame: { [unowned self] f in self.frames.append(f) })
            s.signals = rec
            return s
        }

        private func drawFrame(after seconds: TimeInterval) {
            clock += seconds
            let due = frames
            frames.removeAll()
            for f in due { f() }
        }

        func testEachScreenIsNumberedAndItsFirstFrameTimedFromTheProcessOrItsNavigation() {
            let s = speed()
            s.shown(start: nil, framedAt: clock)
            friction.speed = s
            clock += 2
            tap(centre(screen.bag))
            drawFrame(after: 0.03)
            clock += 1
            s.navigationFramed()
            s.shown(start: clock - 0.2, framedAt: clock)
            XCTAssertEqual([1, 2], rec.numbered)
            guard case .firstFrame(1, true, let launchFcp, nil) = rec.speed[0] else { return XCTFail("\(rec.speed)") }
            XCTAssertEqual(10_000, launchFcp, "from the process's start")
            guard case .tapped(1) = rec.speed[1],
                case .interaction(1, let latency, let processing, let presentation, "button", _) = rec.speed[2]
            else { return XCTFail("\(rec.speed)") }
            XCTAssertEqual(30, latency)
            XCTAssertEqual(0, processing, "delivered as it ended")
            XCTAssertEqual(30, presentation)
            guard case .firstFrame(2, false, let fcp, let inv) = rec.speed[3] else { return XCTFail("\(rec.speed)") }
            XCTAssertEqual(200, fcp)
            XCTAssertEqual(1030, inv, "the tap a second before the navigation caused it")
        }

        func testFramesFromANavigationsFirstFrameAreTheNextScreensAndAnEndedScreenSettlesAfterOneOfTheNext() {
            let s = speed()
            s.shown(start: nil, framedAt: clock)
            s.frame(gap: 1.0 / 60, budget: 1.0 / 60)
            s.frame(gap: 0.05, budget: 1.0 / 60)
            s.navigationFramed()
            s.frame(gap: 0.8, budget: 1.0 / 60)
            s.shown(start: clock, framedAt: clock)
            s.frame(gap: 1.0 / 60, budget: 1.0 / 60)
            let frames = rec.speed.compactMap { signal -> [Int64]? in
                guard case .frames(let screen, let total, let slow, let frozen) = signal else { return nil }
                return [Int64(screen), total, slow, frozen]
            }
            XCTAssertEqual([[1, 2, 1, 0]], frames, "the first screen's, told as it ended")
            XCTAssertTrue(
                rec.speed.contains { if case .settled(1) = $0 { return true } else { return false } },
                "settled once a later screen drew")
            s.hiding()
            XCTAssertEqual(
                [2, 2, 1, 1],
                rec.speed.compactMap { signal -> [Int64]? in
                    guard case .frames(2, let total, let slow, let frozen) = signal else { return nil }
                    return [2, total, slow, frozen]
                }.last, "the transition's frozen frame is the next screen's")
        }

        func testALaunchNotTimedAndAReadyFrame() {
            let s = speed(processStart: nil)
            s.shown(start: nil, framedAt: clock)
            s.ready()
            drawFrame(after: 0.5)
            guard case .firstFrame(1, true, nil, nil) = rec.speed[0] else { return XCTFail("\(rec.speed)") }
            XCTAssertEqual(1, rec.speed.count, "a launch not timed has no full display either")
            s.shown(start: clock - 0.1, framedAt: clock)
            s.ready()
            s.ready()
            drawFrame(after: 0.4)
            guard case .ready(2, 500) = rec.speed.last! else { return XCTFail("\(rec.speed)") }
            XCTAssertEqual(3, rec.speed.count, "asked once")
        }

        // Errors.

        private final class Chained {
            static var calls = 0
        }

        func testAnExceptionIsWrittenWithTheTapBeforeItAndTheHandlerItWrapsRunsAfter() throws {
            // From 0 whatever ran before, so the test holds when run again in one process (`-test-iterations`).
            Chained.calls = 0
            let dir = temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = FileStore(baseDir: dir)
            let context = CrashContext(
                dir: store.directory()!, view: "view-1", session: "s", device: "d", user: nil, org: nil, signals: nil,
                context: ContextSnapshot(appId: "com.example.shop", libraryName: "kontala-ios", libraryVersion: "0"),
                rules: switches.frictionRules!, now: { 1_000_000 }, after: 0)
            var visible = true
            let crashes = Crashes(
                context: { context }, lastTap: { [unowned self] in self.friction.lastTap },
                visible: { visible }, now: { [unowned self] in self.clock })
            NSSetUncaughtExceptionHandler { _ in Chained.calls += 1 }
            crashes.install()
            defer { crashes.uninstall() }
            tap(centre(screen.pay))
            clock += 0.065
            let e = NSException(
                name: .internalInconsistencyException, reason: "Payment 42 failed for anna@example.com", userInfo: nil)
            NSGetUncaughtExceptionHandler()?(e)
            XCTAssertEqual(1, Chained.calls, "the handler it wraps runs after")
            let file = store.directory()!.appendingPathComponent(CrashContext.file)
            let line = try String(contentsOf: file, encoding: .utf8)
            let row = try XCTUnwrap(Json.decodeObject(line.trimmingCharacters(in: .newlines)))
            let error = row.obj("fields")?.obj("error")
            XCTAssertEqual("NSInternalInconsistencyException", error?.str("name"))
            XCTAssertEqual("Payment <n> failed for <email>", error?.str("message"))
            XCTAssertEqual(165, error?.long("since_click_ms"), "from the tap's start")
            XCTAssertEqual("Pay", row.obj("fields")?.obj("element")?.str("text"))
            XCTAssertEqual("view-1", row.str("view"))
            visible = false
            XCTAssertFalse(
                crashes.record(NSException(name: .rangeException, reason: "out of range", userInfo: nil)),
                "never while the app is hidden")
            crashes.uninstall()
            XCTAssertNotNil(NSGetUncaughtExceptionHandler())
            NSGetUncaughtExceptionHandler()?(e)
            XCTAssertEqual(2, Chained.calls, "the handler it wrapped is put back")
            NSSetUncaughtExceptionHandler(nil)
        }
    }
#endif
