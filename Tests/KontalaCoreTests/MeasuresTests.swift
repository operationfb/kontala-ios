import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// What the core's measure plugins send of what the platform reads: rage, dead and disabled taps, swipes, scroll depth,
/// speed, returns and an error written as the process ends, by the rules the Flutter and Android SDKs keep, on a
/// virtual clock.
final class MeasuresTests: XCTestCase {
    private var dirs: [String] = []

    override func setUp() { Kontala.debugReset() }

    override func tearDown() {
        Kontala.debugReset()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs.removeAll()
    }

    private func tempDir() -> String {
        let d = temporaryDirectory()
        dirs.append(d)
        return d
    }

    /// A session on contract 2 on its first screen, showing what [print] answers.
    private func session(
        _ options: KontalaOptions = KontalaOptions(), served: JSONObject? = contract2(), storage: String? = nil,
        start: Int64 = goldenStartMicros, print: (() -> Int64?)? = { 1 }
    ) -> Session {
        let s = startKontala(options, facts: testFacts(storageDir: storage), served: served, start: start)
        s.platform.fingerprinter = print
        s.onCore { $0.screenNumbered(1) }
        Kontala.screen("/catalogue")
        s.scheduler.runDue()
        return s
    }

    private let returns = TapTarget(
        role: "button", declared: .addToCart, text: "Free returns", className: "UIButton",
        path: "MeasuresViewController > UIScrollView > UIButton")

    private func press(
        _ s: Session, _ t: TapTarget? = nil, control: AnyObject? = nil, excluded: Bool = false, x: Double = 100,
        y: Double = 200, print: Int64? = 1
    ) {
        let target = t ?? returns
        s.onCore {
            $0.pressed(
                FrictionPress(
                    hit: target, target: target, control: control, excluded: excluded, x: x, y: y, input: "touch",
                    fingerprint: print))
        }
    }

    private func sent(_ s: Session, _ kind: String) -> [JSONObject] {
        s.sendAll()
        return s.collector.named(kind)
    }

    // Dead taps.

    func testATapNothingAnsweredIsADeadTapFiledUnderItsScreensView() {
        let s = session()
        press(s, control: RouteRef(self))
        s.advanceMillis(8000)
        let dead = sent(s, "dead_click")
        XCTAssertEqual(1, dead.count)
        XCTAssertEqual(["outcome": "none", "wait_ms": 1000], dead.first?.obj("dead"))
        XCTAssertEqual(
            ["role": "button", "text": "Free returns", "class": "UIButton"], dead.first?.obj("element"))
        XCTAssertNil(dead.first?["click_type"], "a click type is a click's")
        XCTAssertEqual("touch", dead.first?.str("input"))
        XCTAssertEqual(100.0, dead.first?["x"]?.number)
        XCTAssertEqual(s.collector.named("page_view").first?.str("id"), dead.first?.str("view"))
    }

    func testATapAnsweredWithinItsWaitIsNoDeadTapAndOneAnsweredPastItIsLate() {
        var shows: Int64 = 1
        let s = session(print: { shows })
        press(s, control: RouteRef(self))
        s.advanceMillis(500)
        s.onCore { $0.answered() }
        s.advanceMillis(8000)
        XCTAssertEqual([], sent(s, "dead_click"), "a scroll answered it")

        press(s, control: RouteRef(NSObject()))
        s.advanceMillis(2500)
        shows = 2
        s.advanceMillis(8000)
        let dead = sent(s, "dead_click").first?.obj("dead")
        XCTAssertEqual("late", dead?.str("outcome"))
        XCTAssertEqual(3000, dead?.long("late_ms"), "answered at the check after its answer")
    }

    func testATapOnADisabledControlIsADeadTapAtOnceAndOneOnAFieldIsNone() {
        let s = session()
        var soldOut = returns
        soldOut.disabled = true
        soldOut.text = "XL sold out"
        press(s, soldOut, control: RouteRef(self))
        press(s, TapTarget(role: "textbox", label: "Email"), control: RouteRef(NSObject()))
        s.advanceMillis(8000)
        let dead = sent(s, "dead_click")
        XCTAssertEqual(["disabled"], dead.map { $0.obj("dead")!.str("outcome")! })
        XCTAssertEqual("XL sold out", dead.first?.obj("element")?.str("text"))
    }

    func testADeadTapIsLeftWhereTheAppWentAwayPastItsWaitAndDroppedWithinIt() {
        let s = session()
        press(s, control: RouteRef(self))
        s.advanceMillis(2500)
        s.lifecycle(.inactive)
        s.lifecycle(.hidden)
        XCTAssertEqual(["left"], sent(s, "dead_click").map { $0.obj("dead")!.str("outcome")! })
        s.finish()

        let t = session()
        press(t, control: RouteRef(self))
        t.advanceMillis(500)
        t.lifecycle(.inactive)
        t.lifecycle(.hidden)
        XCTAssertEqual([], sent(t, "dead_click"), "inside its wait it cannot be told")
    }

    func testAnAlertOverTheAppAnswersATapAsItComesBack() {
        let s = session()
        press(s, control: RouteRef(self))
        s.advanceMillis(300)
        s.lifecycle(.inactive)
        s.advanceMillis(4000)
        s.lifecycle(.resumed)
        s.advanceMillis(8000)
        XCTAssertEqual([], sent(s, "dead_click"))
    }

    func testOneControlsRepeatedTapIsOneCandidateAndNoFingerprintIsNoCandidate() {
        let s = session()
        let control = RouteRef(self)
        press(s, control: control)
        s.advanceMillis(200)
        press(s, control: control)
        press(s, control: RouteRef(NSObject()), print: nil)
        s.advanceMillis(8000)
        XCTAssertEqual(1, sent(s, "dead_click").count)
    }

    // Rage taps.

    func testTapsInAFlurryOnOneSpotAreARageTapMarkedDeadWhereNothingAnswered() {
        let s = session()
        for i in 0..<3 {
            press(s, control: RouteRef(self), x: 100 + Double(i), y: 200)
            s.advanceMillis(100)
        }
        s.advanceMillis(1500)
        let rage = sent(s, "rage_click")
        XCTAssertEqual(1, rage.count)
        XCTAssertEqual(["clicks": 3, "duration_ms": 200, "dead": true], rage.first?.obj("rage"))
        XCTAssertEqual("Free returns", rage.first?.obj("element")?.str("text"))
        XCTAssertEqual(100.0, rage.first?["x"]?.number, "where the burst began")
    }

    func testAFlurryAnsweredIsNotDeadAndAFlurryInAFieldIsNone() {
        let s = session()
        for _ in 0..<3 {
            press(s, control: RouteRef(self))
            s.advanceMillis(100)
        }
        s.onCore { $0.answered() }
        s.advanceMillis(1500)
        XCTAssertNil(sent(s, "rage_click").first?.obj("rage")?["dead"])

        let field = TapTarget(role: "textbox", label: "Notes")
        for _ in 0..<4 {
            press(s, field, control: RouteRef(NSObject()), excluded: true)
            s.advanceMillis(100)
        }
        s.advanceMillis(1500)
        XCTAssertEqual(1, sent(s, "rage_click").count, "a triple tap selects a paragraph")
    }

    func testTapsTooFarApartOrTooSlowAreNoRageTap() {
        let s = session()
        press(s, x: 100)
        s.advanceMillis(100)
        press(s, x: 200)
        s.advanceMillis(100)
        press(s, x: 300)
        s.advanceMillis(1500)
        press(s)
        s.advanceMillis(1100)
        press(s)
        s.advanceMillis(1100)
        press(s)
        s.advanceMillis(1500)
        XCTAssertEqual([], sent(s, "rage_click"))
    }

    func testARageTapEndsAtANavigationUnderTheViewItBeganOn() {
        let s = session()
        for _ in 0..<3 {
            press(s, control: RouteRef(self))
            s.advanceMillis(100)
        }
        s.onCore { $0.screenNumbered(2) }
        Kontala.screen("/still")
        s.scheduler.runDue()
        let rage = sent(s, "rage_click")
        XCTAssertEqual(1, rage.count)
        XCTAssertEqual(s.collector.named("page_view").first?.str("id"), rage.first?.str("view"))
    }

    // Swipes.

    private func swipe(_ s: Session, _ direction: String, _ effect: String) {
        let t = TapTarget(role: "other", text: "Linen shirt", className: "UICollectionView")
        s.onCore {
            $0.swiped(
                Swipe(direction: direction, effect: effect, distance: 300, durationMs: 450, target: t, x: 350, y: 410))
        }
    }

    func testASwipeAcrossACarouselIsSentWithoutWhatItShowsAndOneDownThePageIsScrolling() {
        let s = session()
        swipe(s, "left", "scrolled")
        swipe(s, "up", "scrolled")
        swipe(s, "down", "script")
        let swipes = sent(s, "swipe")
        XCTAssertEqual(2, swipes.count)
        XCTAssertEqual(
            ["direction": "left", "effect": "scrolled", "distance": 300, "duration_ms": 450],
            swipes.first?.obj("swipe"))
        XCTAssertEqual(["role": "other", "class": "UICollectionView"], swipes.first?.obj("element"))
        XCTAssertEqual(350.0, swipes.first?["x"]?.number)
        XCTAssertEqual("script", swipes.last?.obj("swipe")?.str("effect"))
    }

    func testSwipesAreCappedAViewAndNoneIsSentWhereThePropertyCapturesNoScrolling() {
        let s = session()
        let perView = Int(s.core.served.scroll!.swipes.perView)
        for _ in 0..<(perView + 3) { swipe(s, "left", "none") }
        XCTAssertEqual(perView, sent(s, "swipe").count)

        Kontala.debugReset()
        let t = session(served: contract2(scroll: false))
        swipe(t, "left", "scrolled")
        XCTAssertEqual([], sent(t, "swipe"))
    }

    // Scroll depth.

    func testAScreensDepthIsSentAsTheAppIsHiddenAndAgainOnlyDeeper() {
        let s = session()
        s.onCore { $0.scrolled(Reading(1000, 3900, 1000)) }
        s.onCore { $0.scrolled(Reading(1284, 3900, 1000)) }
        s.lifecycle(.hidden)
        s.lifecycle(.resumed)
        s.onCore { $0.scrolled(Reading(1100, 3900, 1000)) }
        s.lifecycle(.hidden)
        s.lifecycle(.resumed)
        s.onCore { $0.scrolled(Reading(2000, 3900, 1000)) }
        s.onCore { $0.screenNumbered(2) }
        Kontala.screen("/still")
        s.scheduler.runDue()
        let depths = sent(s, "scroll_depth")
        XCTAssertEqual(
            [
                ["trigger": "hide", "depth_px": 1284, "height_px": 3900, "viewport_px": 1000, "root": "element"],
                ["trigger": "view", "depth_px": 2000, "height_px": 3900, "viewport_px": 1000, "root": "element"],
            ],
            depths.map { $0.obj("scroll")! })
        let first = s.collector.named("page_view").first?.str("id")
        XCTAssertEqual([first, first], depths.map { $0.str("view") })
    }

    func testAReadingDuringANavigationIsTheScreenLeavingsNeverTheOneLeft() {
        let s = session()
        s.onCore { $0.scrolled(Reading(1500, 3900, 1000)) }
        s.onCore { $0.hub.begin(.push) }
        s.onCore { $0.scrolled(Reading(3900, 3900, 1000)) }
        s.onCore { $0.screenNumbered(2) }
        Kontala.screen("/still")
        s.scheduler.runDue()
        XCTAssertEqual([1500], sent(s, "scroll_depth").map { $0.obj("scroll")!.long("depth_px")! })
    }

    // Speed.

    func testEachScreensSpeedIsSentAsItEndsWithItsLongestTapAndAgainOnceItSettled() {
        let s = session()
        s.onCore {
            $0.measured(.firstFrame(screen: 1, launch: true, fcpMs: 420, invMs: nil))
            $0.measured(.tapped(screen: 1))
            $0.measured(
                .interaction(
                    screen: 1, latencyMs: 30, processingMs: 20, presentationMs: 10, role: "button", path: "A > B"))
            $0.measured(.tapped(screen: 1))
            $0.measured(
                .interaction(
                    screen: 1, latencyMs: 90, processingMs: 70, presentationMs: 20, role: "link", path: "A > C"))
            $0.measured(.frames(screen: 1, total: 120, slow: 3, frozen: 0))
        }
        s.onCore { $0.screenNumbered(2) }
        // What is measured of a screen before its view opens is held for it.
        s.onCore { $0.measured(.firstFrame(screen: 2, launch: false, fcpMs: 180, invMs: 210)) }
        Kontala.screen("/still")
        s.scheduler.runDue()
        s.onCore {
            $0.measured(.frames(screen: 1, total: 130, slow: 4, frozen: 1))
            $0.measured(.settled(screen: 1))
            $0.measured(.ready(screen: 2, lcpMs: 600))
        }
        s.lifecycle(.hidden)
        let speeds = sent(s, "page_speed").map { $0.obj("speed")! }
        XCTAssertEqual(3, speeds.count)
        XCTAssertEqual(
            [
                "trigger": "view", "nav": "launch", "fcp_ms": 420, "inp_ms": 90,
                "inp": [
                    "type": "pointer", "processing_ms": 70, "presentation_ms": 20, "role": "link", "path": "A > C",
                ],
                "interactions": 2, "frames": ["total": 120, "slow": 3, "frozen": 0],
                "supported": ["fcp", "inp", "frames"],
            ],
            speeds[0])
        XCTAssertEqual(["total": 130, "slow": 4, "frozen": 1], speeds[1].obj("frames"), "sent again once settled")
        XCTAssertEqual("view", speeds[1].str("trigger"))
        XCTAssertEqual(
            [
                "trigger": "hide", "fcp_ms": 180, "lcp_ms": 600, "soft": true, "interactions": 0, "inv_ms": 210,
                "supported": ["fcp", "lcp", "inp", "soft", "inv"],
            ],
            speeds[2])
        let views = s.collector.named("page_view").map { $0.str("id") }
        XCTAssertEqual([views[0], views[0], views[1]], sent(s, "page_speed").map { $0.str("view") })
    }

    func testNoSpeedIsSentWhereThePropertyCapturesNoFriction() {
        let s = session(served: contract2(friction: false))
        s.onCore { $0.measured(.firstFrame(screen: 1, launch: true, fcpMs: 420, invMs: nil)) }
        s.lifecycle(.hidden)
        XCTAssertEqual([], sent(s, "page_speed"))
        XCTAssertEqual([], s.collector.named("page_restore"))
    }

    // Returns.

    func testAReturnWithinTheVisitIsARestoreFiledUnderTheViewItCameBackTo() {
        let s = session()
        s.lifecycle(.hidden)
        s.advanceMillis(5000)
        s.lifecycle(.resumed)
        let restore = sent(s, "page_restore")
        XCTAssertEqual([["away_ms": 5000, "restores": 1]], restore.map { $0.obj("restore")! })
        XCTAssertEqual(s.collector.named("page_view").first?.str("id"), restore.first?.str("view"))
    }

    // Errors.

    func testAnErrorWrittenAsTheProcessEndsIsSentByTheNextLaunchUnderTheViewItHappenedOn() throws {
        let dir = tempDir()
        let s = session(storage: dir)
        let view = try XCTUnwrap(sent(s, "page_view").first?.str("id"))
        let context = try XCTUnwrap(s.core.crashContext, "published as each granted event is released")
        let pay = TapTarget(role: "button", text: "Pay", className: "UIButton")
        let recorder = CrashRecorder()
        XCTAssertTrue(
            recorder.record(
                Thrown(
                    name: "NSInternalInconsistencyException",
                    message: "Payment 42 failed for anna@example.com\n(the stack)", source: "ios:ShopApp/PayButton"),
                context, tap: TapBefore(ms: 65, fields: pay.toFields())))
        XCTAssertFalse(
            recorder.record(
                Thrown(
                    name: "NSInternalInconsistencyException", message: "Payment 43 failed for bob@example.com",
                    source: "ios:ShopApp/PayButton"),
                context, tap: nil), "the same error is written once")
        let file = URL(fileURLWithPath: dir).appendingPathComponent("kontala").appendingPathComponent(
            CrashContext.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "written before the process ends")
        let at = s.scheduler.nowMicros
        s.finish()

        let next = startKontala(facts: testFacts(storageDir: dir), served: contract2(), start: at)
        next.advanceMillis(500)
        next.sendAll()
        let error = next.collector.named("js_error")
        XCTAssertEqual(1, error.count)
        XCTAssertEqual(
            [
                "kind": "error", "name": "NSInternalInconsistencyException",
                "message": "Payment <n> failed for <email>",
                "source": "ios:ShopApp/PayButton", "since_click_ms": 65,
            ],
            error.first?.obj("error"))
        XCTAssertEqual("Pay", error.first?.obj("element")?.str("text"))
        XCTAssertEqual(view, error.first?.str("view"))
        XCTAssertEqual("granted", error.first?.str("consent"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "sent once")
        next.finish()
    }

    func testNoErrorIsWrittenWhereThePropertyCapturesNoFrictionOrNothingMayBeStored() {
        let dir = tempDir()
        let s = session(served: contract2(friction: false), storage: dir)
        XCTAssertNil(s.core.crashContext)
        s.finish()
        let t = session(KontalaOptions(consent: .unknown), storage: tempDir())
        XCTAssertNil(t.core.crashContext, "nothing is written while consent is unknown")
        Kontala.consent(.granted)
        t.scheduler.runDue()
        XCTAssertNotNil(t.core.crashContext)
    }

    func testConsentWithdrawnAnOptOutOrAResetLeavesACrashNothingToBeWrittenWith() throws {
        for leave in [{ Kontala.consent(.denied) }, { Kontala.optOut(true) }, { Kontala.reset() }] {
            let s = session(storage: tempDir())
            XCTAssertNotNil(s.core.crashContext)
            leave()
            s.scheduler.runDue()
            XCTAssertNil(s.core.crashContext, "no row stamped granted, or with the ids left behind")
            s.finish()
        }
    }

    func testAnOptOutDeletesACrashsRowWaitingForTheNextLaunch() throws {
        let dir = tempDir()
        let file = URL(fileURLWithPath: dir).appendingPathComponent("kontala").appendingPathComponent(CrashContext.file)
        func crash(_ s: Session) throws {
            let context = try XCTUnwrap(s.core.crashContext)
            XCTAssertTrue(
                CrashRecorder().record(
                    Thrown(name: "NSInternalInconsistencyException", message: "No size chart"), context, tap: nil))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        // A process an app's own handler kept alive, whose visitor opts out.
        let s = session(storage: dir)
        try crash(s)
        Kontala.optOut(true)
        s.scheduler.runDue()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "deleted with the rest of the queue")
        s.finish()

        // A row an earlier process left, at a launch whose visitor had opted out.
        let t = session(storage: dir)
        Kontala.optOut(false)
        Kontala.screen("/product/42")
        t.scheduler.runDue()
        try crash(t)
        t.finish()
        let meta = URL(fileURLWithPath: dir).appendingPathComponent("kontala").appendingPathComponent(Core.meta)
        try Data(#"{"opted_out":true}"#.utf8).write(to: meta)
        let next = startKontala(facts: testFacts(storageDir: dir), served: contract2())
        next.advanceMillis(500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "deleted as the launch clears the queue")
        next.sendAll()
        XCTAssertEqual([], next.collector.named("js_error"))
        next.finish()
    }

    func testAnExceptionsSourceIsTheFirstFrameOfTheAppsOwnCodeAndOneTheSDKRaisedIsNone() {
        let app = "/private/var/containers/Bundle/Application/1A2B/ShopApp.app"
        func frame(_ image: String, _ symbol: String?, _ offset: Int? = 64) -> Messages.NativeFrame {
            Messages.NativeFrame(image: image, symbol: symbol, offset: offset)
        }
        let cf = frame("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", "__exceptionPreprocess")
        let objc = frame("/usr/lib/libobjc.A.dylib", "objc_exception_throw")
        let array = frame("/System/Library/Frameworks/Foundation.framework/Foundation", "-[NSArray objectAtIndex:]")
        let uikit = frame(
            "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", "-[UIApplication sendEvent:]")
        let sdk = frame(app + "/ShopApp", "$s7Kontala9TapReaderC4readyySo7UIEventCF")
        // The kernel names the bundle under /var, the bundle itself under /private/var.
        let pay = frame("/var/containers/Bundle/Application/1A2B/ShopApp.app/ShopApp", "$s7ShopApp4CartC3payyyF")
        let kit = frame(app + "/Frameworks/ShopKit.framework/ShopKit", nil, nil)
        let main = frame(app + "/ShopApp", "main")
        XCTAssertEqual(
            .app("ios:ShopApp/Cart"), Messages.iosOrigin([cf, objc, array, sdk, pay, uikit, main], appRoot: app),
            "past the SDK's own frame, the app's")
        XCTAssertEqual(.sdk, Messages.iosOrigin([cf, objc, sdk, pay, main], appRoot: app), "raised by the SDK")
        XCTAssertEqual(
            .app("ios:ShopKit"), Messages.iosOrigin([cf, objc, kit, main], appRoot: app),
            "a framework of the app's that names no symbol")
        XCTAssertEqual(
            .app(nil), Messages.iosOrigin([cf, objc, array, uikit, main], appRoot: app),
            "no code of the app's but its entry point")
        XCTAssertEqual(
            .app("ios:ShopApp"),
            Messages.iosOrigin([cf, objc, frame(app + "/ShopApp", "$s7ShopApp4CartC3payyyF", 900_000)], appRoot: app),
            "a symbol far before its frame is another function's")
    }

    func testAnErrorPastItsTapsWindowNamesNoTapAndACapHoldsAView() throws {
        let s = session(storage: tempDir())
        let context = try XCTUnwrap(s.core.crashContext)
        let recorder = CrashRecorder()
        let perView = context.rules.errorsPerView
        var written = 0
        for i in 0..<(perView + 2) {
            // Each its own error: a number in a message is normalised away, and two alike are one.
            let step = String(repeating: "x", count: i + 1)
            if recorder.record(
                Thrown(name: "NSRangeException", message: "failed at step \(step)", source: nil), context,
                tap: TapBefore(ms: 5000, fields: JSONObject()))
            {
                written += 1
            }
        }
        XCTAssertEqual(perView, written)
        XCTAssertFalse(recorder.record(Thrown(name: "", message: "  "), context, tap: nil), "an error saying nothing")
        XCTAssertFalse(
            recorder.record(Thrown(name: "Error", message: "ResizeObserver loop limit exceeded"), context, tap: nil))
    }
}
