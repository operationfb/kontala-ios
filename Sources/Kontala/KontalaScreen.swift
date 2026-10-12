#if os(iOS)
    import Foundation
    import KontalaCore
    import SwiftUI
    import UIKit

    /// Declares the screen a view controller shows: its name, its page type and its data, as the Flutter SDK's
    /// `KontalaScreen` widget does. Each wins over what Kontala would work out, and each is read as the screen is shown,
    /// at the frame after it appeared.
    ///
    /// ```swift
    /// final class ProductViewController: UIViewController, KontalaScreen {
    ///     var kontalaScreenName: String? { "/product/\(product.id)" }
    ///     var kontalaPageType: KontalaPageType? { .productDetail }
    /// }
    /// ```
    ///
    /// A name that starts with `/` is a path, so page type rules on paths read app screens as they read pages.
    public protocol KontalaScreen: AnyObject {
        /// The screen's name, or nil for the one Kontala works out.
        var kontalaScreenName: String? { get }

        /// The screen's page type, which always wins.
        var kontalaPageType: KontalaPageType? { get }

        /// Data the screen view carries as its data layer.
        var kontalaScreenProperties: [String: Any]? { get }
    }

    extension KontalaScreen {
        public var kontalaScreenName: String? { nil }
        public var kontalaPageType: KontalaPageType? { nil }
        public var kontalaScreenProperties: [String: Any]? { nil }
    }

    extension View {
        /// Declares the screen this view is, as `KontalaScreen` declares a view controller's: its name, its page type
        /// and its data. Put it on a screen's root view, a navigation destination's or a sheet's: SwiftUI shows each in
        /// a hosting controller of its own, whose screen view it names.
        ///
        /// ```swift
        /// ProductView(product: product)
        ///     .kontalaScreen("/product/\(product.id)", pageType: .productDetail)
        /// ```
        ///
        /// A SwiftUI screen nothing declares is named by its navigation title, and one with neither is not sent.
        public func kontalaScreen(
            _ name: String? = nil, pageType: KontalaPageType? = nil, properties: [String: Any]? = nil
        ) -> some View {
            background(ScreenMarker(name: name, pageType: pageType, properties: properties))
        }
    }

    /// An invisible view behind a SwiftUI screen, which hands its declaration to the hosting controller it is in.
    struct ScreenMarker: UIViewRepresentable {
        let name: String?
        let pageType: KontalaPageType?
        let properties: [String: Any]?

        func makeUIView(context: Context) -> ScreenMarkerView {
            let v = ScreenMarkerView()
            v.isUserInteractionEnabled = false
            v.isAccessibilityElement = false
            return v
        }

        func updateUIView(_ view: ScreenMarkerView, context: Context) {
            let props = properties.flatMap { jsonSafe($0)?.object }
            view.declare(ScreenDeclaration(name: name, pageType: pageType, properties: props))
        }
    }

    final class ScreenMarkerView: UIView {
        private var declaration: ScreenDeclaration?

        func declare(_ d: ScreenDeclaration) {
            declaration = d
            publish()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        private func publish() {
            guard window != nil, let d = declaration, let owner = owner() else { return }
            ScreenDeclarations.set(d, for: owner)
        }

        /// The view controller this view is in, the hosting controller SwiftUI shows the screen in.
        private func owner() -> UIViewController? {
            var r: UIResponder? = next
            while let x = r {
                if let vc = x as? UIViewController { return vc }
                r = x.next
            }
            return nil
        }
    }

    /// What SwiftUI screens declare, by the hosting controller each is in, held weakly, on the main thread.
    enum ScreenDeclarations {
        private final class Box {
            let declaration: ScreenDeclaration
            init(_ d: ScreenDeclaration) { declaration = d }
        }

        private static let table = NSMapTable<UIViewController, Box>.weakToStrongObjects()

        static func of(_ vc: UIViewController) -> ScreenDeclaration? {
            table.object(forKey: vc)?.declaration
        }

        /// Keeps [d] for [vc]; a declaration that changed once its screen was told amends the screen view while it is
        /// unsent, as a screen whose data arrives after it is shown does.
        static func set(_ d: ScreenDeclaration, for vc: UIViewController) {
            let was = of(vc)
            table.setObject(Box(d), forKey: vc)
            if was != d { ScreenWatcher.current?.declarationChanged(vc, d) }
        }
    }
#endif
