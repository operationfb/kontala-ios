# Kontala shop for iOS

A demo shop that captures with `kontala-ios`, for end-to-end runs against a local collector, the native counterpart of the Flutter and Android SDKs' examples.
Half of it is UIKit and half SwiftUI, each SwiftUI screen in a hosting controller pushed onto the app's UIKit navigation:

- **Home** (UIKit): a paged carousel of campaigns a swipe moves, and the products in a table, with search, account and the cart in the navigation bar.
- **Product** (UIKit): declared a product page with its data, a declared add to cart that says on the page how many are in the cart, a photo that loads before the page calls `Kontala.screenReady()`, a disabled button, one nothing answers, and one that answers three seconds late.
- **Cart** (UIKit): what is in the basket, and a declared begin checkout, disabled while it is empty.
- **Checkout** (SwiftUI): address fields told apart by their content types, a card number the app masks, the way to Delivery and returns, a declared purchase, and the order's confirmation.
- **Account** (SwiftUI): a declared login whose email names who signs in, the keyboard's Done on the password, iOS's tracking prompt, and the app's own analytics consent, which the pages it shows take as theirs.
- **Search** (SwiftUI): the keyboard's Search sends the box's term, and a result opens its product.
- **Delivery and returns** (UIKit, from a product): `example/in-app.html`, a page of the shop's website with the Kontala tag on it, in a `WKWebView` attached with `Kontala.attachWebView`, so the page is the app's visitor and visit, takes the app's consent and signed-in user, and counts the screen with its own page views.
  From the checkout, the same page in SwiftUI (`DeliveryPage`), whose own `UIViewRepresentable` attaches its web view as it makes it and detaches it as SwiftUI takes it down.

**Size guide crashes the app on purpose**: an Objective-C exception nothing catches ends the app, and the next launch sends its `js_error`.

## Run it against a local collector

1. Start `collector-file` from `.claude/launch.json` (port 8788, `SINK=stdout`, `EVENTS_API=on`): its demo key, `pk_live_demo_000000000000000000000000`, captures clicks, scrolling, friction and the Events API's custom events, and the shop uses it by default.
2. For Delivery and returns, build the tag with `npm run build:tag` and serve the repository on port 4173 (`examples` in `.claude/launch.json`, `npx serve . -l 4173` at the root).
   The simulator reaches both as `localhost`, and the shop's Info.plist allows plain http to local addresses alone (`NSAllowsLocalNetworking`), which the SDK never needs.
3. Open `KontalaShop.xcodeproj` and run the `KontalaShop` scheme on an iPhone simulator, or from here:

   ```sh
   xcodebuild build -project KontalaShop.xcodeproj -scheme KontalaShop -destination 'platform=iOS Simulator,name=iPhone 16'
   ```

   Build settings name what it sends to and shows, each overridden on the command line: `KONTALA_COLLECTOR=http://<host>:<port>`, `KONTALA_WRITE_KEY=`, `KONTALA_WEBSITE=`, `KONTALA_SESSION_MINUTES=2` to shorten a visit, and `KONTALA_WEBVIEW=none` to leave Delivery and returns' web view unattached, so the visitor and visit are shared through the cookie store alone and the screen keeps its screen view.
4. Read what arrived in the collector's output: one JSON row per event, `page_view` rows with `url` of `app://la.konta.example.shop/...`, `click` rows with their `details.element`, and `scroll_depth`, `swipe`, `page_speed`, `js_error`, `rage_click`, `dead_click`, `page_restore` and `view_time` rows filed under their screen view's `page_id`.
   A debug build, and any build in the simulator, is a developer's: its rows carry `is_allowed_origin: false`.
   The page's own rows reach the same collector with the same key, as `source` `browser`, each naming the app (`host_app_id`), with the app's device and session.

`KontalaShopUITests` drives a visit through every screen with real touches: `xcodebuild test -project KontalaShop.xcodeproj -scheme KontalaShop -destination 'platform=iOS Simulator,name=iPhone 16' -parallel-testing-enabled NO`.
`testThePageKeepsTheAppsVisit`, run alone with `KONTALA_SESSION_MINUTES=2`, stays three and a half minutes on Delivery and returns, its page changing route every 50 seconds, and comes back to the app in the same visit.
`testTheAppKeepsThePagesVisit`, run the same way, stays three and a half minutes in the app with a tap every 50 seconds, and opens Delivery and returns again, whose page continues the visit; with `KONTALA_WEBVIEW=none` only the cookies the app slid can carry it.
`testColdLaunches` launches the shop seven times, sending each launch's speed; run alone once as it is and once with `KONTALA_WRITE_KEY=` a key whose property lists no website and `KONTALA_WEBSITE=` (empty), it compares a launch with websites to share against one with none, and the first launch of each, which reads the configuration from the network, is the one to leave out.
A key with no website is one added to a copy of `collector/tenants.example.json` with `"allowed_origins": []`, which `TENANT_CONFIG_PATH` names to the collector.
XCUITest turns accessibility on, and the SDK reads none of what iOS makes up for it, so its rows are what a visitor's would be.

A link opens a product with a campaign's tags:

```sh
xcrun simctl openurl booted "kontalashop://shop/product/42?utm_source=push&utm_campaign=autumn"
```

The SDK's debug log is in Console, under the subsystem `la.konta.kontala`:

```sh
xcrun simctl spawn booted log stream --predicate 'subsystem == "la.konta.kontala"'
```

`project.py` writes `KontalaShop.xcodeproj` from the sources in `KontalaShop/` and `KontalaShopUITests/`: run `python3 project.py` here after adding a file, and commit what it writes.
