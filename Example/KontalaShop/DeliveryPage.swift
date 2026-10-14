import Kontala
import SwiftUI
import WebKit

/// Delivery and returns in SwiftUI, from the checkout: the page `DeliveryViewController` shows, in a `WKWebView` the
/// screen's own `UIViewRepresentable` makes, attached as it is made and detached as SwiftUI takes it down, which is
/// how a SwiftUI app attaches one.
struct DeliveryPage: View {
    var body: some View {
        AttachedWebView(url: DeliveryViewController.page())
            .ignoresSafeArea(edges: .bottom)
            .kontalaScreen("/help/delivery")
    }
}

/// A `WKWebView` for SwiftUI, attached to Kontala before its first load unless the build says `none`.
struct AttachedWebView: UIViewRepresentable {
    let url: URL

    final class Coordinator {
        var attachment: KontalaWebViewAttachment?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Before the first load: the bridge reaches only the pages loaded after it.
        if Settings.attachesWebView { context.coordinator.attachment = Kontala.attachWebView(web) }
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.attachment?.detach()
    }
}
