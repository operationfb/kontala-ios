#if os(iOS)
    import UIKit
    import XCTest

    @testable import Kontala

    /// A SwiftUI app's `App.init` runs before UIKit has made the app: a start there waits for the launch to finish,
    /// once, and an app extension, which never has an app, starts nothing.
    final class LaunchTests: XCTestCase {
        func testAStartBeforeTheAppExistsBeginsOnceAsTheLaunchFinishes() {
            let center = NotificationCenter()
            var app: NSObject?
            var begun: [NSObject] = []
            Launch.when({ app }, center: center, isExtension: false) { begun.append($0) }
            XCTAssertEqual([], begun)

            app = NSObject()
            center.post(name: UIApplication.didFinishLaunchingNotification, object: nil)
            XCTAssertEqual([app!], begun)
            center.post(name: UIApplication.didFinishLaunchingNotification, object: nil)
            XCTAssertEqual([app!], begun)
        }

        func testAStartOnceTheAppExistsBeginsAtOnce() {
            let center = NotificationCenter()
            let app = NSObject()
            var begun: [NSObject] = []
            Launch.when({ app }, center: center, isExtension: false) { begun.append($0) }
            XCTAssertEqual([app], begun)
            center.post(name: UIApplication.didFinishLaunchingNotification, object: nil)
            XCTAssertEqual([app], begun)
        }

        func testAnAppExtensionStartsNothing() {
            let center = NotificationCenter()
            var app: NSObject?
            var begun: [NSObject] = []
            Launch.when({ app }, center: center, isExtension: true) { begun.append($0) }
            app = NSObject()
            center.post(name: UIApplication.didFinishLaunchingNotification, object: nil)
            XCTAssertEqual([], begun)
        }
    }
#endif
