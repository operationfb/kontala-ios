#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit
    import WebKit

    extension Kontala {
        /// Attaches [webView] to Kontala, on the main thread, as the screen showing it is built and before its first
        /// `load`, since a page finds the bridge only when it was loaded after. A page on one of the websites the app
        /// shows, with the Kontala tag on it, is then told the app's consent and signed-in user, the app is told the
        /// page's activity and its own sign-in, and a screen the web view fills is counted by the page's own page
        /// views. Detach the attachment as the web view goes.
        ///
        /// The visitor and the visit are shared without it, through the cookies every web view on the default website
        /// data store shares; before `start`, the attachment does nothing.
        @discardableResult
        public static func attachWebView(_ webView: WKWebView) -> KontalaWebViewAttachment {
            guard let r = current else { return InertAttachment() }
            guard Thread.isMainThread else {
                r.warn("[kontala] attachWebView must be called on the main thread, where WebKit is used")
                return InertAttachment()
            }
            return WebBridge.attach(r, webView)
        }
    }

    /// The bridge between the app and the Kontala tag on a page it shows in a web view (collector/webview), iOS's side
    /// of `Kontala.attachWebView`: the global a page posts to, `window.KontalaAppBridge`, which a script at document
    /// start defines in the main frame alone, and only while the app's handler is there, and the web view as the core
    /// reads it, its URL and the share of its window it covers, and runs the app's answer in. The core answers only a
    /// page on one of the websites, in the main frame, and takes nothing after the hello without the nonce it gave that
    /// page, which a frame of another origin cannot read.
    enum WebBridge {
        /// What a page finds as `window.KontalaAppBridge`, forwarding each message as text to the app's handler.
        static let script =
            "(function(){if(window.KontalaAppBridge)return;var w=window.webkit,h=w&&w.messageHandlers&&"
            + "w.messageHandlers.\(WebViews.bridgeChannel);if(!h)return;window.KontalaAppBridge={postMessage:"
            + "function(m){try{h.postMessage(String(m));}catch(e){}}};})();"

        static func attach(_ r: Kontala.Running, _ webView: WKWebView) -> KontalaWebViewAttachment {
            let handle = Handle(r, webView)
            let host = Host(webView)
            // A web view in no window yet is being built for the screen about to open; one on show already is the
            // screen on show's.
            let pending = webView.window == nil
            // Posted ahead of anything the page can post, so the attachment is there for its hello.
            r.post { core in handle.attached = core.attachWebView(host, pending: pending) }
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: WebViews.bridgeChannel)
            controller.add(Receiver(handle), name: WebViews.bridgeChannel)
            if !controller.userScripts.contains(where: { $0.source == script }) {
                controller.addUserScript(
                    WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            return handle
        }

        /// The attachment the app holds; what reaches the core is posted to its queue.
        final class Handle: KontalaWebViewAttachment {
            private let r: Kontala.Running
            private weak var webView: WKWebView?
            private let lock = NSLock()
            private var detachedFlag = false

            /// The core's attachment, set on the core's queue before anything the page posts reaches it.
            var attached: WebAttachment?

            init(_ r: Kontala.Running, _ webView: WKWebView) {
                self.r = r
                self.webView = webView
            }

            private var detached: Bool {
                lock.lock()
                defer { lock.unlock() }
                return detachedFlag
            }

            func receive(_ message: String) {
                if detached { return }
                r.post { [weak self] _ in self?.attached?.receive(message) }
            }

            func detach() {
                lock.lock()
                let was = detachedFlag
                detachedFlag = true
                lock.unlock()
                if was { return }
                r.post { [self] _ in attached?.detach() }
                r.main { [weak webView] in
                    webView?.configuration.userContentController.removeScriptMessageHandler(
                        forName: WebViews.bridgeChannel)
                }
            }
        }

        /// What a page posts, taken from the main frame alone: a frame of another origin can reach the handler too,
        /// but the bridge's script defines its global in the main frame only.
        final class Receiver: NSObject, WKScriptMessageHandler {
            private let handle: Handle

            init(_ handle: Handle) {
                self.handle = handle
            }

            func userContentController(
                _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
            ) {
                guard message.frameInfo.isMainFrame, let body = message.body as? String else { return }
                handle.receive(body)
            }
        }

        /// A web view as the core reads it, on the main thread, held weakly so an attachment never keeps one alive.
        final class Host: WebViewHost {
            private weak var webView: WKWebView?

            init(_ webView: WKWebView) {
                self.webView = webView
            }

            func inspect(_ done: @escaping (String?, Double) -> Void) {
                DispatchQueue.main.async { [weak self] in
                    guard let w = self?.webView else { return done(nil, 0) }
                    done(w.url?.absoluteString, WebBridge.coverage(w))
                }
            }

            func runJavaScript(_ source: String) {
                DispatchQueue.main.async { [weak self] in
                    self?.webView?.evaluateJavaScript(source, completionHandler: nil)
                }
            }
        }

        /// The share of its window [v] covers, from 0 to 1: a web view that is the screen, rather than a part of it.
        /// One hidden, faded out, in a hidden view or in no window covers nothing.
        static func coverage(_ v: UIView) -> Double {
            guard let w = v.window, ScreenKinds.visible(v) else { return 0 }
            let area = w.bounds.width * w.bounds.height
            guard area > 0 else { return 0 }
            let shown = v.convert(v.bounds, to: nil).intersection(w.bounds)
            if shown.isNull { return 0 }
            return min(1, max(0, Double(shown.width * shown.height / area)))
        }
    }
#endif
