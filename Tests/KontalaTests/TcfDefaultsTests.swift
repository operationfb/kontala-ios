#if os(iOS)
    import XCTest

    @testable import Kontala
    @testable import KontalaCore

    /// The IAB TCF keys a consent manager writes in the app's standard UserDefaults, in the simulator: read as stored,
    /// the TC string only as there or not, and a change to them told once, off the main thread, whichever defaults
    /// object wrote it, where a change to anything else is not told.
    final class TcfDefaultsTests: XCTestCase {
        private let written = [
            "IABTCF_CmpSdkID", "IABTCF_gdprApplies", "IABTCF_PurposeConsents", "IABTCF_PublisherConsent",
            "IABTCF_TCString", "kontala_test_theme",
        ]

        override func setUp() { clear() }

        override func tearDown() { clear() }

        private func clear() {
            for key in written { UserDefaults.standard.removeObject(forKey: key) }
        }

        func testTheKeysAreReadAsAConsentManagerStoresThem() {
            let tcf = TcfDefaults()
            XCTAssertEqual(["tc_string_present": false], tcf.keys())
            let defaults = UserDefaults.standard
            defaults.set(300, forKey: "IABTCF_CmpSdkID")
            defaults.set(1, forKey: "IABTCF_gdprApplies")
            defaults.set("10000001", forKey: "IABTCF_PurposeConsents")
            defaults.set("CQabc.not.handed.over", forKey: "IABTCF_TCString")
            XCTAssertEqual(
                [
                    "IABTCF_CmpSdkID": 300, "IABTCF_gdprApplies": 1, "IABTCF_PurposeConsents": "10000001",
                    "tc_string_present": true,
                ],
                tcf.keys())
            XCTAssertEqual(
                [
                    "1": true, "2": false, "3": false, "4": false, "5": false, "6": false, "7": false, "8": true,
                    "9": false, "10": false, "11": false,
                ],
                Dictionary(uniqueKeysWithValues: readTcf(tcf.keys()).answer!.answers.map { ($0.key, $0.value) }))
        }

        func testAChangeToTheKeysIsToldOnceWhicheverObjectWroteIt() {
            let tcf = TcfDefaults()
            let lock = NSLock()
            var told = 0
            var onMain = false
            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return told
            }
            /// Runs the main run loop until [n] changes were told, or for at most [seconds].
            func settle(_ n: Int, _ seconds: Double = 5) {
                let end = Date().addingTimeInterval(seconds)
                while count() < n && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            }
            tcf.watch {
                lock.lock()
                told += 1
                onMain = onMain || Thread.isMainThread
                lock.unlock()
            }

            UserDefaults.standard.set("dark", forKey: "kontala_test_theme")
            settle(1, 0.3)
            XCTAssertEqual(0, count(), "a change to anything else is not told")
            UserDefaults.standard.set("11111111111", forKey: "IABTCF_PurposeConsents")
            settle(1)
            XCTAssertEqual(1, count())
            UserDefaults().set("1", forKey: "IABTCF_PublisherConsent")
            settle(2)
            XCTAssertEqual(2, count(), "a change through a defaults object of the consent manager's own")
            UserDefaults.standard.set("1", forKey: "IABTCF_PublisherConsent")
            settle(3, 0.3)
            XCTAssertEqual(2, count(), "a key written again as it was")
            lock.lock()
            XCTAssertFalse(onMain, "told off the main thread, where every change here was written")
            lock.unlock()
        }
    }
#endif
