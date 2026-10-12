/// A web view attached to Kontala with `Kontala.attachWebView`: detach it as the web view goes.
public protocol KontalaWebViewAttachment: AnyObject {
    /// The web view is gone: its pages are answered no more, and a page it loads after finds no bridge.
    func detach()
}

/// An attachment where the SDK does nothing: before `Kontala.start`, or once it has stopped.
package final class InertAttachment: KontalaWebViewAttachment {
    package init() {}

    package func detach() {}
}
