import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// The configuration client, as the Flutter SDK's contract tests hold it.
final class ConfigClientTests: XCTestCase {
    /// Answers each read of the configuration with `next`, and keeps what it was asked.
    private final class Answers: Http {
        struct Offline: Error {}

        var next: () -> HttpAnswer? = { HttpAnswer(404) }
        var urls: [String] = []
        var headers: [[String: String]] = []

        func post(
            _ url: String, _ headers: [String: String], _ body: Data,
            _ done: @escaping (HttpAnswer?, Error?) -> Void
        ) {
            fatalError("the configuration is only read")
        }

        func get(_ url: String, _ headers: [String: String], _ done: @escaping (HttpAnswer?, Error?) -> Void) {
            urls.append(url)
            self.headers.append(headers)
            if let a = next() { done(a, nil) } else { done(nil, Offline()) }
        }
    }

    /// Holds every read until the test lets it go.
    private final class Slow: Http {
        let answers: Answers
        var held: [() -> Void] = []

        init(_ answers: Answers) { self.answers = answers }

        func post(
            _ url: String, _ headers: [String: String], _ body: Data,
            _ done: @escaping (HttpAnswer?, Error?) -> Void
        ) {
            fatalError("the configuration is only read")
        }

        func get(_ url: String, _ headers: [String: String], _ done: @escaping (HttpAnswer?, Error?) -> Void) {
            held.append { self.answers.get(url, headers, done) }
        }
    }

    private var dir = ""
    private var store: FileStore!
    private let answers = Answers()
    private var changes: [ServedConfig] = []
    private var halts = 0
    private let scheduler = FakeScheduler()

    override func setUp() {
        dir = temporaryDirectory()
        store = FileStore(baseDir: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func client() -> ConfigClient {
        ConfigClient(
            endpoint: "https://eu.konta.la/v1/events", writeKey: "pk_live_test", store: store, clock: Clock(),
            libraryVersion: "0.1.0", http: answers, scheduler: scheduler,
            onChange: { [unowned self] in self.changes.append($0) },
            onHalt: { [unowned self] in self.halts += 1 })
    }

    private func served(_ doc: JSONObject) -> HttpAnswer { HttpAnswer(200, Data(Json.encode(doc).utf8)) }

    private func read(_ c: ConfigClient) {
        c.refresh(force: true)
        scheduler.runDue()
    }

    func testReadsTheConfigurationWithTheWriteKeyKeepsItAndStartsTheNextLaunchWithIt() {
        answers.next = { self.served(contract2()) }
        let c = client()
        XCTAssertEqual(1, c.current.contract, "a launch with nothing kept writes contract 1")
        read(c)
        XCTAssertEqual(["https://eu.konta.la/v1/events/config"], answers.urls)
        XCTAssertEqual("Bearer pk_live_test", answers.headers.first?["Authorization"])
        XCTAssertEqual(2, c.current.contract)
        XCTAssertEqual(["rev-2"], changes.map(\.rev))
        XCTAssertTrue(store.exists(ConfigClient.file))

        let next = client()
        next.loadKept()
        XCTAssertEqual(2, next.current.contract)
        XCTAssertNotNil(next.current.scroll)
    }

    func testA304KeepsWhatIsKeptAndAsksWithItsRevision() {
        answers.next = { self.served(contract2()) }
        read(client())
        answers.next = { HttpAnswer(304) }
        let c = client()
        c.loadKept()
        changes.removeAll()
        read(c)
        XCTAssertEqual("\"rev-2\"", answers.headers.last?["If-None-Match"])
        XCTAssertEqual(2, c.current.contract)
        XCTAssertTrue(changes.isEmpty)
    }

    func testA404OrA405IsACollectorFromBeforeContract2Contract1Kept() {
        answers.next = { self.served(contract2()) }
        read(client())
        for status in [404, 405] {
            answers.next = { HttpAnswer(status) }
            let c = client()
            c.loadKept()
            read(c)
            XCTAssertEqual(1, c.current.contract)
            let again = client()
            again.loadKept()
            XCTAssertEqual(1, again.current.contract, "a region rolled back past contract 2")
        }
    }

    func testAnotherAnswerOrNoneKeepsTheKeptOneAndALaunchWithNoneWritesContract1() {
        answers.next = { HttpAnswer(503) }
        let none = client()
        read(none)
        XCTAssertEqual(1, none.current.contract)

        answers.next = { self.served(contract2()) }
        read(client())
        let nexts: [() -> HttpAnswer?] = [
            { HttpAnswer(503) }, { HttpAnswer(500) }, { nil }, { HttpAnswer(200, Data("<html>".utf8)) },
        ]
        for next in nexts {
            answers.next = next
            let c = client()
            c.loadKept()
            read(c)
            XCTAssertEqual(2, c.current.contract)
        }
    }

    func testA401StopsSendingAsARefusedKeyStopsItOnPost() {
        answers.next = { HttpAnswer(401) }
        read(client())
        XCTAssertEqual(1, halts)
    }

    func testNothingIsKeptWhileStorageIsNotAllowed() {
        store.writable = false
        answers.next = { self.served(contract2()) }
        let c = client()
        read(c)
        XCTAssertEqual(2, c.current.contract)
        XCTAssertFalse(store.exists(ConfigClient.file))
        store.writable = true
        c.keep()
        XCTAssertTrue(store.exists(ConfigClient.file), "kept once consent allows it")
    }

    func testIsReadAgainOnlyOnceStaleUnlessForcedOneReadAtATime() {
        answers.next = { self.served(contract2()) }
        let c = client()
        // One read in flight: the second asks nothing more.
        let slow = Slow(answers)
        let c2 = ConfigClient(
            endpoint: "https://eu.konta.la/v1/events", writeKey: "pk_live_test", store: store, clock: Clock(),
            libraryVersion: "0.1.0", http: slow, scheduler: scheduler)
        c2.refresh(force: true)
        c2.refresh(force: true)
        XCTAssertEqual(1, slow.held.count)
        for h in slow.held { h() }
        scheduler.runDue()
        XCTAssertEqual(1, answers.urls.count)
        c2.refresh()
        XCTAssertEqual(1, slow.held.count, "fresh for five minutes")
        read(c)
        XCTAssertEqual(2, answers.urls.count)
    }

    func testACollectorRefusingAFieldItDoesNotReadIsContract1UntilItsConfigurationSaysAgain() {
        answers.next = { self.served(contract2()) }
        let c = client()
        read(c)
        answers.next = { HttpAnswer(404) }
        c.refused()
        XCTAssertEqual(1, c.current.contract)
        scheduler.runDue()
        XCTAssertEqual(2, answers.urls.count)
    }

    func testTheConfigurationIsReadBesideTheEventsEndpoint() {
        XCTAssertEqual(ConfigClient.configURL("https://konta.la/v1/events"), "https://konta.la/v1/events/config")
        XCTAssertEqual(ConfigClient.configURL("https://konta.la/v1/events/"), "https://konta.la/v1/events/config")
        XCTAssertEqual(
            ConfigClient.configURL("http://localhost:8788/v1/events?x=1#y"), "http://localhost:8788/v1/events/config")
    }
}
