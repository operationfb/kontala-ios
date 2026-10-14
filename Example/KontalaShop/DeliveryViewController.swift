import Kontala
import UIKit
import WebKit

/// Delivery and returns: `example/in-app.html`, a page of the shop's website with the Kontala tag on it, in a web
/// view attached with `Kontala.attachWebView`, so the page is the app's visitor and visit, takes the app's consent
/// and signed-in user, and counts the screen with its own page views. A build with `KONTALA_WEBVIEW=none` leaves it
/// unattached, sharing the visitor and visit through the cookie store alone.
final class DeliveryViewController: UIViewController, KontalaScreen {
    var kontalaScreenName: String? { "/help/delivery" }

    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var attachment: KontalaWebViewAttachment?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Delivery and returns"
        navigationItem.largeTitleDisplayMode = .never
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        // Before the first load: the bridge reaches only the pages loaded after it.
        if Settings.attachesWebView { attachment = Kontala.attachWebView(web) }
        web.load(URLRequest(url: Self.page()))
    }

    deinit { attachment?.detach() }

    /// The page on the website the app shows, sending to the same collector with the same key and idle timeout.
    static func page() -> URL {
        var c = URLComponents(string: "\(Settings.website)/example/in-app")!
        c.queryItems = [
            URLQueryItem(name: "collector", value: "\(Settings.collector)/v1/collect?k=\(Settings.writeKey)"),
            URLQueryItem(name: "timeout", value: "\(Settings.sessionMinutes)"),
        ]
        return c.url!
    }
}
