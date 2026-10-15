import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// Sessions through the API alone, on the core; the sessions with screens and taps arrive with the UIKit phases.
final class GoldensTests: XCTestCase {
    override func setUp() { Kontala.debugReset() }

    override func tearDown() { Kontala.debugReset() }

    /// Runs [script] as a session against a fake collector, and holds what it sent to its golden.
    private func golden(
        _ name: String, _ description: String, options: KontalaOptions = KontalaOptions(), served: JSONObject? = nil,
        ids: DeviceIds? = nil, capture: JSONObject = ["data_layer": "discover", "clicks": true],
        refused: [JSON] = [], tcf: JSONObject? = nil, file: StaticString = #filePath, line: UInt = #line,
        _ script: (Session) -> Void
    ) {
        let s = startKontala(options, served: served, ids: ids, tcf: tcf)
        script(s)
        s.sendAll()
        s.finish()
        holdToGolden(
            name, description, capture: capture, refused: refused, requests: s.collector.requests,
            file: file, line: line)
    }

    // Sessions every app SDK runs with the same calls: the Flutter SDK's
    // goldens of these names are the reference
    // (sdk/flutter/kontala_flutter/test/goldens_test.dart). Change one, change
    // them all.

    func testAVisitThroughTheApiAlone() {
        golden(
            "api_visit",
            "Screens the app names itself, the first opened by a link with UTM tags, a page type and properties, a "
                + "custom event, identify with traits, a page type declared once its screen view was sent, the app "
                + "hidden and shown again within its visit: what every app SDK sends for the same calls.",
            options: KontalaOptions(friction: false),
            served: contract2(),
            ids: DeviceIds(idfv: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", adTracking: "not_determined"),
            capture: ["data_layer": "discover", "clicks": true, "scroll": true, "friction": true]
        ) { s in
            Kontala.screen("/?utm_source=push&utm_campaign=autumn")
            s.firstFrame()
            s.advanceMillis(1000)
            Kontala.screen(
                "/product/42", pageType: .productDetail,
                properties: ["product": ["id": "42", "price": 79.0, "tags": ["linen", "summer"]]])
            s.advanceMillis(1000)
            Kontala.track("wishlisted", properties: ["product_id": "42", "sizes": ["M", "L"]])
            Kontala.identify(user: "customer-42", org: "acme", traits: ["plan": "pro"])
            s.advanceMillis(2000)
            s.sendAll()
            Kontala.pageType(.productList)
            s.advanceMillis(1000)
            s.lifecycle(.inactive)
            s.lifecycle(.hidden)
            s.advanceMillis(5000)
            s.lifecycle(.inactive)
            s.lifecycle(.resumed)
            s.advanceMillis(1000)
            s.lifecycle(.inactive)
            s.lifecycle(.hidden)
        }
    }

    func testAVisitThroughTheApiUnderConsentTheAppAsksForThenDenied() {
        golden(
            "api_consent",
            "Events held while consent is unknown and released as denied, through the API alone: what every app "
                + "SDK sends for the same calls.",
            options: KontalaOptions(consent: .unknown)
        ) { s in
            Kontala.screen("/")
            s.firstFrame()
            s.advanceMillis(1000)
            Kontala.track("size_selected", properties: ["size": "M"])
            Kontala.consent(.denied)
            s.scheduler.runDue()
        }
    }

    func testAVisitThroughTheApiRecordingWhatTheVisitorAnsweredInAConsentManager() {
        golden(
            "consent_visit",
            "A region on contract 3, and a consent manager that wrote the IAB TCF keys of a visitor who accepted "
                + "storage and measurement alone: events held until the app's own consent, which records its answer "
                + "for analytics, the app's answer for functional, then the visitor accepting everything in the "
                + "consent manager, each change a consent_change under the screen it came on, and a denial, whose "
                + "change is not sent and whose events record it: what every app SDK sends for the same calls.",
            // Friction is off, as in api_visit: its speed is measured from frames.
            options: KontalaOptions(consent: .unknown, friction: false),
            served: contract3(),
            capture: ["data_layer": "discover", "clicks": true, "scroll": true, "friction": true, "consent": true],
            tcf: tcfMeasureOnly
        ) { s in
            Kontala.screen("/")
            s.firstFrame()
            s.advanceMillis(1000)
            Kontala.consent(.granted)
            s.advanceMillis(1000)
            Kontala.setConsentSignals(functional: true)
            s.advanceMillis(1000)
            Kontala.screen("/product/42")
            s.advanceMillis(1000)
            s.platform.writeTcf(tcfAll)
            s.advanceMillis(1000)
            Kontala.consent(.denied)
            s.advanceMillis(1000)
            Kontala.track("wishlisted", properties: ["product_id": "42"])
            s.advanceMillis(1000)
            s.lifecycle(.inactive)
            s.lifecycle(.hidden)
        }
    }
}
