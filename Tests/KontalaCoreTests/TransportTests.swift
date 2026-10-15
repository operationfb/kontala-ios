import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// The transport against a real collector on a local port, through the platform's HTTP client and the SDK's own
/// queue, as the other SDKs' transport tests run against a real socket.
final class TransportTests: XCTestCase {
    private var dir = ""
    private var rigs: [Rig] = []
    private var collectors: [LocalCollector] = []

    override func setUp() {
        dir = temporaryDirectory()
    }

    override func tearDown() {
        for r in rigs { r.close() }
        for c in collectors { c.close() }
        rigs.removeAll()
        collectors.removeAll()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func ok(_ body: JSONObject, rejected: [JSON] = []) -> Reply {
        let n = body.list("events")?.count ?? 0
        return Reply(
            status: 200,
            body: Json.encode(
                [
                    "request_id": "r", "accepted": .int(Int64(n - rejected.count)), "rejected": .array(rejected),
                    "warnings": [],
                ] as JSONObject))
    }

    private func ctx() -> ContextSnapshot {
        ContextSnapshot(
            appId: "com.example.shop", displayWidth: 393, displayHeight: 852, libraryName: "kontala-ios",
            libraryVersion: "0.1.0")
    }

    private func ev(_ clock: Clock, _ kind: String, _ fields: JSONObject = JSONObject(), atMicros: Int64? = nil)
        -> CapturedEvent
    {
        let t = atMicros ?? clock.stamp()
        return CapturedEvent(
            id: Ids.uuidV7(t / 1000), kind: kind, atMicros: t, fields: fields, context: ctx(), consent: "granted",
            device: "device-1", session: "session-1")
    }

    private final class Rig {
        let clock = Clock()
        let scheduler = QueueScheduler(label: "kontala-test")
        let http = SessionHttp()
        private let lock = NSLock()
        private var outcomeList: [SendOutcome] = []
        var sender: Sender!
        var queue: EventQueue!

        init(_ endpoint: String, store: FileStore, contract: Int = 1, onContractRefused: (() -> Void)? = nil) {
            sender = Sender(
                endpoint: endpoint, writeKey: "pk_live_test", store: store, clock: clock, libraryVersion: "0.1.0",
                http: http, scheduler: scheduler,
                onOutcome: { [weak self] _, o in
                    guard let self = self else { return }
                    self.lock.lock()
                    self.outcomeList.append(o)
                    self.lock.unlock()
                },
                onContractRefused: onContractRefused)
            queue = EventQueue(
                store: store, encoder: WireEncoder(clock: clock, contract: contract), sender: sender, clock: clock,
                scheduler: scheduler)
        }

        var outcomes: [SendOutcome] {
            lock.lock()
            defer { lock.unlock() }
            return outcomeList
        }

        /// Runs [f] on the SDK's queue and waits for it.
        func run<T>(_ f: @escaping () -> T) -> T {
            let done = DispatchSemaphore(value: 0)
            var out: T?
            scheduler.post {
                out = f()
                done.signal()
            }
            precondition(done.wait(timeout: .now() + 10) == .success, "the SDK's queue did not answer")
            return out!
        }

        func flush() {
            let done = DispatchSemaphore(value: 0)
            scheduler.post { self.queue.flush { done.signal() } }
            precondition(done.wait(timeout: .now() + 10) == .success, "the flush did not end")
        }

        func close() {
            run { self.queue.dispose() }
            run { self.sender.close() }
            scheduler.shutdown()
            http.close()
        }
    }

    private func rig(
        _ endpoint: String, store: FileStore? = nil, contract: Int = 1,
        onContractRefused: (() -> Void)? = nil
    ) -> Rig {
        let r = Rig(
            endpoint, store: store ?? FileStore(baseDir: dir), contract: contract, onContractRefused: onContractRefused)
        rigs.append(r)
        return r
    }

    private func collector(_ answer: @escaping (Int, JSONObject) -> Reply) -> LocalCollector {
        let c = LocalCollector(answer)
        collectors.append(c)
        return c
    }

    private func until(_ timeout: TimeInterval = 10, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end {
                XCTFail("condition not met")
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private var sealedFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir + "/kontala/queue/sealed")) ?? []
    }

    func testARequestNamesItsKeyAndTypeAndARefusalIsReportedByIndex() {
        let c = collector { _, body in
            self.ok(
                body,
                rejected: [
                    ["index": 1, "id": "x", "code": "clicks_off", "message": "this property captures no clicks"]
                ])
        }
        let r = rig(c.endpoint)
        r.run {
            r.queue.add(self.ev(r.clock, "page_view", ["screen": ["name": "/"]]))
            r.queue.add(self.ev(r.clock, "click", ["element": ["role": "button"]]))
        }
        r.flush()
        XCTAssertEqual(c.received.count, 1)
        let got = c.received[0]
        XCTAssertEqual("Bearer pk_live_test", got.headers["authorization"])
        XCTAssertEqual("application/json", got.headers["content-type"])
        XCTAssertNotNil(got.body.str("sent_at"))
        guard case .delivered(let accepted, let refused, _)? = r.outcomes.first else { return XCTFail() }
        XCTAssertEqual(1, accepted)
        XCTAssertEqual(["clicks_off"], refused.map(\.code))
        XCTAssertTrue(sealedFiles.isEmpty, "a final outcome deletes the batch")
    }

    func testA429IsRetriedAfterRetryAfterWithTheSameEvents() {
        let c = collector { n, body in
            n == 0 ? Reply(status: 429, headers: ["Retry-After": "1"]) : self.ok(body)
        }
        let r = rig(c.endpoint)
        r.run {
            r.queue.add(self.ev(r.clock, "track_me"))
            r.queue.seal(force: true)
        }
        until { c.received.count == 2 }
        XCTAssertEqual(c.received[0].ids, c.received[1].ids, "a retry is the same rows")
        XCTAssertGreaterThanOrEqual(c.received[1].atMillis - c.received[0].atMillis, 950)
    }

    func testA413IsSplitInHalfUntilItFits() {
        let c = collector { _, body in (body.list("events")?.count ?? 0) > 2 ? Reply(status: 413) : self.ok(body) }
        let r = rig(c.endpoint)
        r.run { for i in 0..<4 { r.queue.add(self.ev(r.clock, "e\(i)")) } }
        r.flush()
        until { c.received.count == 3 }
        XCTAssertEqual([4, 2, 2], c.received.map { $0.ids.count })
        XCTAssertEqual(c.received[0].ids, c.received[1].ids + c.received[2].ids, "in order")
    }

    func testACollectorThatRefusesContract2IsSentTheBatchAgainAtContract1AndTheCoreIsTold() {
        let c = collector { n, body in
            n == 0
                ? Reply(
                    status: 400,
                    body: Json.encode(
                        [
                            "error": ["code": "unknown_field", "message": "json: unknown field \"scroll\""]
                        ] as JSONObject))
                : self.ok(body)
        }
        let lock = NSLock()
        var refused = 0
        let r = rig(c.endpoint, contract: 2) {
            lock.lock()
            refused += 1
            lock.unlock()
        }
        let view = ev(r.clock, "page_view", ["screen": ["name": "/", "navigation": "launch"]])
        r.run {
            r.queue.add(view)
            let depth = self.ev(
                r.clock, "scroll_depth",
                ["scroll": ["trigger": "hide", "depth_px": 900, "height_px": 1800, "root": "element"]])
            depth.view = view.id
            r.queue.add(depth)
        }
        r.flush()
        until { c.received.count == 2 }
        XCTAssertEqual([view.id], c.received[1].ids, "the same rows, but what contract 2 alone has")
        XCTAssertEqual(["name": "/"] as JSONObject, c.received[1].body.list("events")?[0].object?.obj("screen"))
        until {
            lock.lock()
            defer { lock.unlock() }
            return refused == 1
        }
        XCTAssertTrue(sealedFiles.isEmpty)
    }

    func testACollectorThatRefusesContract3IsSentTheBatchAt2AndRefusingThatTooAt1() {
        let c = collector { n, body in
            n < 2
                ? Reply(
                    status: 400,
                    body: Json.encode(
                        ["error": ["code": "unknown_field", "message": "json: unknown field"]] as JSONObject))
                : self.ok(body)
        }
        let lock = NSLock()
        var refused = 0
        let r = rig(c.endpoint, contract: 3) {
            lock.lock()
            refused += 1
            lock.unlock()
        }
        let signals = KontalaConsentSignals(analytics: false, source: "app", status: "ready", decided: true)
        let view = ev(r.clock, "page_view", ["screen": ["name": "/", "navigation": "launch"]])
        view.signals = signals
        let change = ev(r.clock, "consent_change", ["consent_change": ["answers": ["app": ["analytics": false]]]])
        change.view = view.id
        change.signals = signals
        let depth = ev(
            r.clock, "scroll_depth",
            ["scroll": ["trigger": "hide", "depth_px": 900, "height_px": 1800, "root": "element"]])
        depth.view = view.id
        r.run {
            r.queue.add(view)
            r.queue.add(change)
            r.queue.add(depth)
        }
        r.flush()
        until { c.received.count == 3 }
        XCTAssertEqual([view.id, change.id, depth.id], c.received[0].ids)
        XCTAssertEqual([view.id, depth.id], c.received[1].ids, "what contract 3 alone has left out")
        XCTAssertTrue(
            (c.received[1].body.list("events") ?? []).allSatisfy { $0.object?.contains("consent_signals") == false })
        XCTAssertEqual([view.id], c.received[2].ids, "and then what contract 2 alone has")
        until {
            lock.lock()
            defer { lock.unlock() }
            return refused == 2
        }
        XCTAssertTrue(sealedFiles.isEmpty)
    }

    func testA401StopsSendingForTheProcessAndA400DropsTheBatchAlone() {
        let c = collector { n, _ in
            Reply(
                status: n == 0 ? 400 : 401,
                body: Json.encode(
                    [
                        "error": ["code": .string(n == 0 ? "unknown_field" : "invalid_key"), "message": "no"]
                    ] as JSONObject))
        }
        let r = rig(c.endpoint)
        for name in ["first", "second", "third"] {
            r.run { r.queue.add(self.ev(r.clock, name)) }
            r.flush()
        }
        XCTAssertEqual(2, c.received.count)
        guard case .dropped(_, let code, _)? = r.outcomes.first else { return XCTFail() }
        XCTAssertEqual("unknown_field", code)
        guard r.outcomes.count > 1, case .halted(let halted) = r.outcomes[1] else { return XCTFail() }
        XCTAssertEqual("invalid_key", halted)
        XCTAssertTrue(r.run { r.sender.halted })
    }

    func testABodyOver1KbIsGzipped() {
        let c = collector { _, body in self.ok(body) }
        let r = rig(c.endpoint, store: FileStore(baseDir: nil))
        r.run {
            r.queue.add(self.ev(r.clock, "big", ["properties": ["note": .string(String(repeating: "x", count: 2000))]]))
        }
        r.flush()
        XCTAssertEqual(c.received.count, 1)
        XCTAssertEqual("gzip", c.received.first?.headers["content-encoding"])
        XCTAssertEqual(c.received.first?.body.list("events")?.count, 1)
    }

    func testABatchSealedByAProcessThatDiedIsSentByTheNextLaunchWithTheSameIds() {
        // Nothing listens: the first process's request fails and it is killed.
        let dead = Rig("http://127.0.0.1:9/v1/events", store: FileStore(baseDir: dir))
        let sealedIds: [String] = dead.run {
            dead.queue.add(self.ev(dead.clock, "sealed_one"))
            dead.queue.seal(force: true)
            dead.queue.add(self.ev(dead.clock, "unsealed_one"))
            dead.queue.save()
            return dead.sender.pending.flatMap { b in (b.body.list("events") ?? []).map { $0.object!.str("id")! } }
        }
        dead.close()

        let c = collector { _, body in self.ok(body) }
        let next = rig(c.endpoint)
        next.run { next.queue.restore() }
        next.flush()
        until { c.received.count == 2 }
        XCTAssertEqual(sealedIds, c.received[0].ids, "sealed batches go first, unchanged")
        XCTAssertEqual(["unsealed_one"], c.received[1].body.list("events")?.map { $0.object!.str("event")! })
    }

    func testAnEventOlderThanTheApiTakesIsDroppedRatherThanRefused() {
        let c = collector { _, body in self.ok(body) }
        let r = rig(c.endpoint, store: FileStore(baseDir: nil))
        let monthAgo = (Int64(Date().timeIntervalSince1970 * 1000) - 30 * 24 * 3600 * 1000) * 1000
        r.run {
            r.queue.add(self.ev(r.clock, "stale", atMicros: monthAgo))
            r.queue.add(self.ev(r.clock, "fresh"))
        }
        r.flush()
        XCTAssertEqual(["fresh"], c.received.first?.body.list("events")?.map { $0.object!.str("event")! })
    }
}
