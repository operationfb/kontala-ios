#if os(iOS)
    import Foundation
    import KontalaCore
    import ObjectiveC
    import SwiftUI
    import UIKit

    private var eventKey: UInt8 = 0
    private var maskKey: UInt8 = 0
    private var ignoreKey: UInt8 = 0

    extension UIView {
        /// The click type a tap on this view, or on a view inside it, declares, as `data-ac-event` declares one on the
        /// web: `addToBag.kontalaEvent = .addToCart`. It always wins over the type Kontala would work out.
        public var kontalaEvent: KontalaClickType? {
            get { (objc_getAssociatedObject(self, &eventKey) as? String).flatMap(KontalaClickType.init(rawValue:)) }
            set { objc_setAssociatedObject(self, &eventKey, newValue?.rawValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
        }

        /// Taps on this view, and on every view inside it, are sent with their role alone: no id, label, text or
        /// class, and a path of bare names, as `data-ac-mask` on the web. A form's values are never read under it.
        public var kontalaMask: Bool {
            get { (objc_getAssociatedObject(self, &maskKey) as? Bool) ?? false }
            set { objc_setAssociatedObject(self, &maskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        }

        /// Taps on this view, and on every view inside it, are not captured at all, as `data-ac-ignore` on the web.
        public var kontalaIgnore: Bool {
            get { (objc_getAssociatedObject(self, &ignoreKey) as? Bool) ?? false }
            set { objc_setAssociatedObject(self, &ignoreKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        }
    }

    extension View {
        /// Declares what a tap on this view is, as `kontalaEvent` declares a UIKit view's. SwiftUI draws its own
        /// controls rather than putting a UIKit view under the finger, and with VoiceOver off no public API names the
        /// control a finger was on, so a tap on a SwiftUI control is sent only where it is marked, as the click type,
        /// id and label given here. Its UIKit controls, a `TextField`'s field, a `Toggle`'s switch, a tab bar and a
        /// navigation bar's buttons, are read as UIKit's are.
        ///
        /// ```swift
        /// Button("Add to bag") { bag.add(item) }
        ///     .kontalaEvent(.addToCart, label: "Add to bag")
        /// ```
        public func kontalaEvent(_ type: KontalaClickType? = nil, id: String? = nil, label: String? = nil) -> some View
        {
            background(TapMark(kind: .event(type, id: id, label: label)))
        }

        /// Taps on this view are sent with their role alone, as `kontalaMask` on a UIKit view.
        public func kontalaMask() -> some View { background(TapMark(kind: .mask)) }

        /// Taps on this view are not captured at all, as `kontalaIgnore` on a UIKit view.
        public func kontalaIgnore() -> some View { background(TapMark(kind: .ignore)) }
    }

    /// An invisible view behind a SwiftUI view, whose frame is what a tap is tested against.
    struct TapMark: UIViewRepresentable {
        let kind: TapMarkView.Kind

        func makeUIView(context: Context) -> TapMarkView {
            let v = TapMarkView()
            v.isUserInteractionEnabled = false
            v.isAccessibilityElement = false
            return v
        }

        func updateUIView(_ view: TapMarkView, context: Context) {
            view.kind = kind
        }
    }

    final class TapMarkView: UIView {
        enum Kind: Equatable {
            case event(KontalaClickType?, id: String?, label: String?)
            case mask
            case ignore
        }

        var kind = Kind.mask

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { TapMarks.add(self) }
        }

        /// Where the view is in its window.
        var frameInWindow: CGRect { convert(bounds, to: nil) }
    }

    /// The SwiftUI marks that have been on show, held weakly, on the main thread.
    enum TapMarks {
        private final class Weak {
            weak var view: TapMarkView?
            init(_ v: TapMarkView) { view = v }
        }

        private static var marks: [Weak] = []

        static func add(_ v: TapMarkView) {
            marks.removeAll { $0.view == nil }
            if !marks.contains(where: { $0.view === v }) { marks.append(Weak(v)) }
        }

        /// The marks on show in [window] whose frames hold [point], the smallest first.
        static func at(_ point: CGPoint, in window: UIWindow) -> [TapMarkView] {
            marks.removeAll { $0.view == nil }
            let found = marks.compactMap { $0.view }.filter { v in
                v.window === window && ScreenKinds.visible(v) && v.frameInWindow.contains(point)
            }
            return found.sorted { a, b in
                let fa = a.frameInWindow
                let fb = b.frameInWindow
                return fa.width * fa.height < fb.width * fb.height
            }
        }
    }
#endif
