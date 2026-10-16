# Kontala for iOS

Kontala's analytics SDK for native iOS apps, UIKit and SwiftUI alike.
It captures every screen a visitor sees, every control they tap, who signs in, what their forms and searches sent, how far they scrolled, where the app made them struggle, how fast each screen was and the app's own events, the way Kontala's tag captures a website, and sends them to Kontala's Events API.

It needs iOS 13 or later, and has no dependencies beyond Apple's frameworks.

## Add it

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/operationfb/kontala-ios`, choose Up to Next Minor Version from 0.1.0, and add the Kontala library to the app's target.
In a `Package.swift`:

```swift
dependencies: [.package(url: "https://github.com/operationfb/kontala-ios", .upToNextMinor(from: "0.1.0"))],
targets: [.target(name: "Shop", dependencies: [.product(name: "Kontala", package: "kontala-ios")])]
```

## Start it

Start it as the app starts, on the main thread, with the property's write key and the Events API URL that the property's Events API card in Kontala shows:

```swift
import Kontala

@main
struct ShopApp: App {
    init() { Kontala.start(writeKey: "pk_live_...", endpoint: "https://konta.la/v1/events") }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

The guide, at <https://www.kontala.com/docs/developers/ios-sdk>, says what each capture sends, the options, and what the App Store's privacy questions must say.

## This repository

It is a read-only mirror of the SDK as Kontala builds and tests it, published with each release: every tag is a release, and nothing is merged here.
Its tests and its demo shop's runs read fixtures and a collector from Kontala's own repository, so they run there.

## Licence

The Kontala SDK License, in `LICENSE`.
