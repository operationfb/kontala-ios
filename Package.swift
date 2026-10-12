// swift-tools-version: 5.9
import PackageDescription

// Kontala for a native iOS app. KontalaCore is the Flutter SDK's core ported
// to Swift on Foundation alone, so `swift test` runs it on Linux as well as on
// a Mac; Kontala is UIKit's and WebKit's side, which reads the app's screens,
// lifecycle and web views and hands the core what it read.
let package = Package(
    name: "Kontala",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "Kontala", targets: ["Kontala"])
    ],
    targets: [
        // zlib, which the SDK's own module map reaches on Linux; Apple's SDKs
        // have a module of their own for it.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib", providers: [.apt(["zlib1g-dev"])]),
        .target(
            name: "KontalaCore",
            dependencies: [.target(name: "CZlib", condition: .when(platforms: [.linux]))]
        ),
        .target(
            name: "Kontala",
            dependencies: ["KontalaCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // The fakes both suites run the SDK on; no product names it.
        .target(name: "KontalaTestSupport", dependencies: ["KontalaCore"], path: "Tests/KontalaTestSupport"),
        .testTarget(name: "KontalaCoreTests", dependencies: ["KontalaCore", "KontalaTestSupport"]),
        .testTarget(name: "KontalaTests", dependencies: ["Kontala", "KontalaTestSupport"]),
    ]
)
