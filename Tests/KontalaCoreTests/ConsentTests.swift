import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// collector/consent/testdata/vectors.json, which the collector's, the tag's and the other SDKs' tests read too: the
/// vocabulary, the resolver's rule and what an app makes of its IAB TCF keys cannot drift between them.
final class ConsentVectorsTests: XCTestCase {
    private let v = repoJson("collector/consent/testdata/vectors.json")

    private func cases(_ key: String) -> [JSONObject] { (v.list(key) ?? []).map { $0.object! } }

    private func strings(_ raw: JSON?) -> [String] { (raw?.array ?? []).map { $0.string! } }

    private func map(_ raw: JSON?) -> ConsentMap {
        (raw?.object ?? JSONObject()).map { (key: $0.key, buckets: strings($0.value)) }
    }

    private func catalog(_ raw: JSON?) -> [String: ConsentMap] {
        var out: [String: ConsentMap] = [:]
        for (source, m) in raw?.object ?? JSONObject() { out[source] = map(m) }
        return out
    }

    private func answer(_ raw: JSONObject) -> ConsentAnswer {
        ConsentAnswer(
            source: raw.str("source")!,
            answers: (raw.obj("answers") ?? JSONObject()).map { (key: $0.key, value: $0.value.bool!) },
            decided: raw["decided"]?.bool)
    }

    private func assertJson(_ want: JSON?, _ got: JSONObject, _ message: String, line: UInt = #line) {
        let normal = try! Json.decode(Json.encode(got))
        XCTAssertTrue(
            jsonEquals(normal, want ?? .null),
            "\(message):\n  got  \(Json.encode(normal))\n  want \(Json.encode(want ?? .null))", line: line)
    }

    func testTheSetsAreTheCollectorsInItsOrder() {
        XCTAssertEqual(strings(v["buckets"]), consentBuckets)
        XCTAssertEqual(strings(v["sources"]), consentSources)
        XCTAssertEqual(strings(v["readers"]), consentReaders)
        XCTAssertEqual(strings(v["statuses"]), consentStatuses)
        XCTAssertEqual(v.obj("change")?.str("name"), consentChangeName)
        XCTAssertEqual(v.obj("limits")?.long("max_keys"), Int64(maxConsentKeys))
        XCTAssertEqual(v.obj("limits")?.long("max_key_length"), Int64(maxConsentKeyLength))
    }

    func testAKeyIsOneASourceMayAnswerByTheCollectorsRule() {
        for c in cases("keys") {
            XCTAssertEqual(validConsentKey(c.str("key")!), c["valid"]?.bool, "\"\(c.str("key")!)\"")
        }
    }

    func testResolvesAsTheCollectorResolvesWhateverOrderTheSourcesAreGivenIn() {
        let defaults = catalog(v["defaults"])
        for c in cases("resolve") {
            let maps = defaults.merging(catalog(c["maps"])) { _, own in own }
            let answered = (c.list("answered") ?? []).map { answer($0.object!) }
            let found = strings(c["found"])
            let name = c.str("name")!
            assertJson(c["want"], resolveConsent(answered, found, maps).toJson(), name)
            assertJson(
                c["want"], resolveConsent(answered.reversed(), found.reversed(), maps).toJson(), "\(name), reversed")
        }
    }

    func testAnAppsTcfKeysAreReadAsTheVectorsReadThem() {
        for c in cases("tcf_app") {
            let name = c.str("name")!
            let got = readTcf(c.obj("keys"))
            XCTAssertEqual(got.found, c["found"]?.bool, name)
            guard let a = got.answer else {
                XCTAssertEqual(c["answer"], .null, name)
                continue
            }
            var out = JSONObject()
            var answers = JSONObject()
            for (k, b) in a.answers { answers[k] = .bool(b) }
            out["answers"] = .object(answers)
            if let d = a.decided { out["decided"] = .bool(d) }
            assertJson(c["answer"], out, name)
        }
    }

    func testTheTcfKeysAreTakenAsStoredAndTheTcStringNever() {
        let stored: [String: Any] = [
            "IABTCF_CmpSdkID": 300, "IABTCF_gdprApplies": 1, "IABTCF_PurposeConsents": "10000001",
            "IABTCF_PublisherConsent": ["not", "a", "value"], "IABTCF_TCString": "CQabc.not.handed.over",
            "theme": "dark",
        ]
        XCTAssertEqual(
            tcfKeysOf { stored[$0] },
            [
                "IABTCF_CmpSdkID": 300, "IABTCF_gdprApplies": 1, "IABTCF_PurposeConsents": "10000001",
                "tc_string_present": true,
            ])
        XCTAssertEqual(tcfKeysOf { _ in nil }, ["tc_string_present": false])
        XCTAssertEqual(readTcf(["IABTCF_gdprApplies": "0"]).answer?.answers.isEmpty, true)
        XCTAssertEqual(readTcf(["IABTCF_gdprApplies": false]).answer?.answers.isEmpty, true)
        XCTAssertFalse(readTcf(["IABTCF_PurposeConsents": 101]).found)
        XCTAssertFalse(readTcf(nil).found)
    }

    func testASectionIsReadAsCollectorConsentServesIt() {
        let section: JSONObject = ["v": 1, "sources": v["readers"]!, "maps": v["defaults"]!]
        let s = ConsentSection.parse(.object(section))!
        XCTAssertEqual(s.sources, strings(v["readers"]))
        XCTAssertTrue(s.readsTcf)
        XCTAssertEqual(s.toJson().obj("maps")?.obj("tcf"), v.obj("defaults")?.obj("tcf"))
        var other = section
        other["v"] = 2
        XCTAssertNil(ConsentSection.parse(.object(other)))
        other = section
        other["maps"] = []
        XCTAssertNil(ConsentSection.parse(.object(other)))
    }
}

/// What the visitor answered in a consent manager, recorded on every event at contract 3 (docs/consent.md): the app's
/// own answers over the IAB TCF keys its consent manager writes, and a consent_change when they change after an event
/// carried others, as the Flutter SDK's consent_capture_test holds it. Nothing here decides what is sent: consent
/// does.
final class ConsentCaptureTests: XCTestCase {
    override func setUp() { Kontala.debugReset() }

    override func tearDown() { Kontala.debugReset() }

    private func signals(_ e: JSONObject?) -> JSONObject? { e?.obj("consent_signals") }

    /// Every purpose of IAB TCF from 1 to 11, consented where [yes] says.
    private func purposes(_ yes: Set<Int>) -> JSONObject {
        var o = JSONObject()
        for p in 1...11 { o["\(p)"] = .bool(yes.contains(p)) }
        return o
    }

    private func readyFrom(
        _ source: String, functional: Bool? = nil, analytics: Bool? = nil, targeting: Bool? = nil
    ) -> JSONObject {
        KontalaConsentSignals(
            functional: functional, analytics: analytics, targeting: targeting, source: source, status: "ready",
            decided: true
        ).toJson()
    }

    func testARegionServingNoConsentSectionIsSentNothingOfTheAnswersWhichAreNotEvenRead() {
        let s = startKontala(served: contract2(), tcf: tcfMeasureOnly)
        Kontala.setConsentSignals(analytics: false)
        Kontala.screen("/product/42")
        s.advanceMillis(1000)
        s.sendAll()
        XCTAssertFalse(s.collector.events.isEmpty)
        XCTAssertTrue(s.collector.events.allSatisfy { !$0.contains("consent_signals") })
        XCTAssertEqual([], s.collector.named("consent_change"))
        XCTAssertNil(Kontala.consentSignals)
        XCTAssertEqual(0, s.platform.tcfReads)
        s.finish()
    }

    func testEveryEventRecordsTheTcfAnswersAndTheAppsOwnOutrankThem() {
        let s = startKontala(served: contract3(), tcf: tcfMeasureOnly)
        Kontala.screen("/product/42")
        s.advanceMillis(1000)
        XCTAssertEqual(
            KontalaConsentSignals(
                functional: false, analytics: true, targeting: false, source: "tcf", status: "ready", decided: true),
            Kontala.consentSignals)
        Kontala.setConsentSignals(targeting: true)
        s.advanceMillis(1000)
        Kontala.track("wishlisted")
        s.sendAll()

        let view = s.collector.named("page_view").last
        XCTAssertEqual(readyFrom("tcf", functional: false, analytics: true, targeting: false), signals(view))
        let change = s.collector.named("consent_change")
        XCTAssertEqual(1, change.count)
        XCTAssertEqual(view?.str("id"), change.first?.str("view"), "filed under the screen it changed on")
        XCTAssertEqual("granted", change.first?.str("consent"))
        XCTAssertEqual(
            ["answers": ["app": ["targeting": true], "tcf": .object(purposes([1, 8]))]],
            change.first?.obj("consent_change"))
        let after = readyFrom("app", functional: false, analytics: true, targeting: true)
        XCTAssertEqual(after, signals(change.first))
        XCTAssertEqual(after, signals(s.collector.named("wishlisted").first))
        s.finish()
    }

    func testAConsentManagersChangeIsReadAsItIsToldAndAgainAsTheAppComesBack() {
        let s = startKontala(served: contract3(), tcf: tcfMeasureOnly)
        Kontala.screen("/")
        s.advanceMillis(1000)
        s.platform.writeTcf(tcfAll)
        s.advanceMillis(10)
        let reads = s.platform.tcfReads
        s.lifecycle(.inactive)
        s.lifecycle(.hidden)
        s.lifecycle(.inactive)
        s.lifecycle(.resumed)
        XCTAssertEqual(reads + 1, s.platform.tcfReads, "read again as the app comes back")
        s.sendAll()

        let change = s.collector.named("consent_change")
        XCTAssertEqual(1, change.count)
        XCTAssertEqual(
            ["answers": ["tcf": .object(purposes(Set(1...11)))]], change.first?.obj("consent_change"))
        XCTAssertEqual(readyFrom("tcf", functional: true, analytics: true, targeting: true), signals(change.first))
        s.finish()
    }

    func testHeldEventsRecordTheAnswerTheyWaitedForAndAChangeIsSentOnlyUnderAGrant() {
        let s = startKontala(KontalaOptions(consent: .unknown), served: contract3(), tcf: tcfMeasureOnly)
        Kontala.screen("/")
        s.advanceMillis(1000)
        Kontala.consent(.granted)
        s.advanceMillis(1000)
        Kontala.consent(.denied)
        s.advanceMillis(1000)
        Kontala.track("size_selected")
        s.sendAll()

        let view = s.collector.named("page_view").first
        XCTAssertEqual("granted", view?.str("consent"))
        XCTAssertEqual(
            readyFrom("app", functional: false, analytics: true, targeting: false), signals(view),
            "Kontala.consent answers for analytics, over the TCF keys")
        XCTAssertEqual([], s.collector.named("consent_change"))
        let after = s.collector.named("size_selected").first
        XCTAssertEqual("denied", after?.str("consent"))
        XCTAssertEqual(.bool(false), signals(after)?["analytics"])
        s.finish()
    }

    func testAPendingConsentManagerIsRecordedAsOneAndItsAnswerAsAChange() {
        let s = startKontala(served: contract3(), tcf: ["IABTCF_CmpSdkID": 300, "IABTCF_gdprApplies": 1])
        Kontala.screen("/")
        s.advanceMillis(1000)
        s.platform.writeTcf(tcfMeasureOnly)
        s.advanceMillis(10)
        s.sendAll()
        XCTAssertEqual(["source": "tcf", "status": "pending"], signals(s.collector.named("page_view").last))
        XCTAssertEqual("ready", signals(s.collector.named("consent_change").first)?.str("status"))
        s.finish()
    }
}
