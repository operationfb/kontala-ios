import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// What the vectors cannot say: files, timers and a clock, as the Flutter SDK's core tests hold them.
final class CoreTests: XCTestCase {
    private var dirs: [String] = []
    private let minute: Int64 = 60_000

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs.removeAll()
    }

    private func tempDir() -> String {
        let d = temporaryDirectory()
        dirs.append(d)
        return d
    }

    private func event(_ kind: String) -> CapturedEvent {
        CapturedEvent(
            id: kind, kind: kind, atMicros: 0, fields: JSONObject(),
            context: ContextSnapshot(appId: "com.example.shop", libraryName: "kontala-ios", libraryVersion: "0"))
    }

    func testIdentityWritesNothingWhileStorageIsNotAllowedAndDeletesWhatItWroteWhenItStopsBeing() {
        let store = FileStore(baseDir: tempDir())
        let id = Identity(store: store)
        _ = id.resolve(0)
        id.flush()
        XCTAssertFalse(store.exists(Identity.file))
        id.setStorageAllowed(true)
        XCTAssertTrue(store.exists(Identity.file))
        id.setStorageAllowed(false)
        XCTAssertFalse(store.exists(Identity.file))
    }

    func testAStoredDeviceBecomesLegibleOnceStorageIsAllowed() {
        let dir = tempDir()
        let first = Identity(store: FileStore(baseDir: dir))
        first.setStorageAllowed(true)
        let stored = first.resolve(0).device
        let id = Identity(store: FileStore(baseDir: dir))
        let before = id.resolve(minute).device
        XCTAssertNotEqual(stored, before, "under unknown consent the device is in memory")
        id.setStorageAllowed(true)
        XCTAssertEqual(stored, id.resolve(2 * minute).device)
    }

    func testAPinnedIdIsNeverWrittenAndNeverRotates() {
        let store = FileStore(baseDir: tempDir())
        let id = Identity(store: store, pinnedDevice: "demo-device", pinnedSession: "demo-session")
        id.setStorageAllowed(true)
        let a = id.resolve(0)
        let b = id.resolve(600 * minute)
        XCTAssertEqual("demo-device", a.device)
        XCTAssertEqual("demo-session", b.session)
        XCTAssertNil(store.readJson(Identity.file)?["device"])
    }

    func testAStoreThatCannotWriteLatchesOffAndTheIdsStayInMemory() throws {
        let dir = tempDir()
        try "not a directory".write(toFile: dir + "/kontala", atomically: true, encoding: .utf8)
        let store = FileStore(baseDir: dir)
        let id = Identity(store: store)
        id.setStorageAllowed(true)
        let a = id.resolve(0)
        XCTAssertFalse(store.available)
        XCTAssertEqual(a.device, id.resolve(minute).device)
    }

    func testAPrincipalReplacesBothHalvesAndTakesAnEmailButDropsAnInvalidIdWithOneWarning() {
        var warnings: [String] = []
        let p = Principal(warn: { warnings.append($0) })
        p.set(user: "u-1", org: "acme")
        p.set(user: "u-2")
        XCTAssertEqual("u-2", p.user)
        XCTAssertNil(p.org, "no event is filed with a new user and an old organisation")
        p.set(user: "anna@example.com")
        XCTAssertEqual("anna@example.com", p.user)
        p.set(user: "anna de vries")
        p.set(user: "anna de vries")
        XCTAssertNil(p.user)
        XCTAssertEqual(1, warnings.count)
        let q = Principal()
        q.set(org: "acme")
        let (u1, o1) = namedPrincipal(q, user: "anna@example.com", org: "other")
        XCTAssertEqual("anna@example.com", u1)
        XCTAssertEqual("acme", o1)
        let (u2, o2) = namedPrincipal(q, user: "not valid")
        XCTAssertNil(u2)
        XCTAssertEqual("acme", o2)
    }

    func testTheGatePassesAnsweredEventsAtOnceAndHoldsUnknownOnesUntilTheAnswer() {
        let scheduler = FakeScheduler()
        var released: [([String], KontalaConsent, Bool)] = []
        let gate = ConsentGate(initial: .unknown, holdMicros: 10_000_000, maxHeld: 3, scheduler: scheduler) {
            e, s, held in released.append((e.map(\.kind), s, held))
        }
        gate.offer(event("page_view"))
        gate.offer(event("click"))
        XCTAssertTrue(released.isEmpty)
        gate.set(.granted)
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released[0].0, ["page_view", "click"])
        XCTAssertEqual(released[0].1, .granted)
        XCTAssertTrue(released[0].2)
        gate.offer(event("click"))
        XCTAssertEqual(released.last?.0, ["click"])
        XCTAssertEqual(released.last?.1, .granted)
        XCTAssertEqual(released.last?.2, false)
    }

    func testAFullBufferGoingToTheBackgroundAndTheHoldReleaseAsUnknown() {
        let scheduler = FakeScheduler()
        var released: [(Int, KontalaConsent)] = []
        let gate = ConsentGate(initial: .unknown, holdMicros: 10_000_000, maxHeld: 2, scheduler: scheduler) {
            e, s, _ in released.append((e.count, s))
        }
        gate.offer(event("a"))
        gate.offer(event("b"))
        gate.offer(event("c"))
        gate.onHidden()
        XCTAssertEqual(released.map(\.0), [2, 1])
        XCTAssertEqual(released.map(\.1), [.unknown, .unknown])
        gate.offer(event("d"))
        scheduler.advance(9_999_999)
        XCTAssertEqual(2, released.count)
        scheduler.advance(1)
        XCTAssertEqual(released.last?.0, 1, "the hold's end")
        XCTAssertEqual(released.last?.1, .unknown)
    }

    func testStampsStrictlyIncreaseInRfc3339WithMicroseconds() {
        let fixed: Int64 = 1_791_453_600_120_000  // 2026-10-08T10:00:00.120Z
        let clock = Clock(wallMicros: { fixed })
        let a = clock.stamp()
        let b = clock.stamp()
        XCTAssertTrue(b > a)
        XCTAssertEqual("2026-10-08T10:00:00.120000Z", rfc3339(a))
        XCTAssertEqual("2026-10-08T10:00:00.120001Z", rfc3339(b))
    }

    func testADeviceClockADayOffIsCorrectedFromTheServersAtSendTime() {
        let day: Int64 = 86_400_000_000
        let clock = Clock(wallMicros: { 1_791_540_000_000_000 })  // 2026-10-09T10:00Z
        let captured = clock.stamp()
        let mono = clock.monotonicMicros
        clock.observeServerTime((1_791_540_000_000_000 - day) / 1000)  // 2026-10-08T10:00Z
        XCTAssertTrue(clock.skewed)
        let sent = clock.sendTime(captured, mono)
        XCTAssertTrue(abs(sent - (1_791_540_000_000_000 - day)) < 5_000_000)
        XCTAssertEqual(captured, clock.sendTime(captured, nil), "an event from an earlier process is sent as captured")
    }

    func testAnHttpDateIsReadInEachOfItsThreeForms() {
        XCTAssertEqual(parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"), 784_111_777_000)
        XCTAssertEqual(parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"), 784_111_777_000)
        XCTAssertEqual(parseHttpDate("Sun Nov  6 08:49:37 1994"), 784_111_777_000)
        XCTAssertNil(parseHttpDate("yesterday"))
    }

    func testABodyIsGzippedAndReadBack() {
        let body = Data(String(repeating: "{\"event\":\"page_view\"}", count: 200).utf8)
        let zipped = gzip(body)!
        XCTAssertLessThan(zipped.count, body.count / 4)
        XCTAssertEqual(Array(zipped.prefix(2)), [0x1F, 0x8B], "gzip's magic number")
        XCTAssertEqual(gunzip(zipped), body)
    }

    func testJsonWritesWhatDartWrites() throws {
        XCTAssertEqual(
            Json.encode(["a": 700.0, "b": 79.5, "c": 1e-7, "d": 1e21, "e": 0.000001] as JSONObject),
            #"{"a":700.0,"b":79.5,"c":1e-7,"d":1e+21,"e":0.000001}"#)
        XCTAssertEqual(Json.encode(.double(1.2345678901234568e20)), "123456789012345680000.0")
        XCTAssertEqual(Json.encode(.double(-0.0)), "-0.0")
        XCTAssertEqual(Json.encode(.double(.nan)), "null")
        XCTAssertEqual(Json.encode(.string("a/b\u{1}\"\n")), #""a/b\u0001\"\n""#)
        let round = try Json.decode(#"{"z":1,"a":[true,null,"😀"],"m":1.5}"#)
        XCTAssertEqual(round.object?.keys, ["z", "a", "m"])
        XCTAssertEqual(round.object?.list("a")?[2], .string("😀"))
        XCTAssertEqual(Json.encode(round), #"{"z":1,"a":[true,null,"😀"],"m":1.5}"#)
    }
}
