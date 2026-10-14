#if os(iOS)
    import Foundation
    import UIKit
    import WebKit

    /// A fingerprint of what the app shows, the Flutter SDK's `appFingerprint` and the Android SDK's, for telling
    /// whether a tap was answered when nothing cheaper says so: every window's views on show, each one's class, what
    /// each label and text view says, each image view's image, each control's state and selection, each cell's
    /// selection and each scroll view's offset; and, where SwiftUI draws, each of its layers' frames and contents. A
    /// control's highlight as it is pressed changes none of it, so a tap's own feedback is no answer; a favourite whose
    /// icon changed is, and so is a screen, a sheet or an alert opened or closed. What a visitor types is left out,
    /// being no answer to a tap, and so is a web view's page, which a tap of the app's never reads.
    ///
    /// Nil where the walk ran out of its budget, which can then say nothing. Read on the main thread.
    enum Fingerprints {
        static let maxNodes = 8000

        static func of(
            _ windows: [UIWindow], debug: Bool,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) -> Int64? {
            var walk = Walk(deadline: now() + (debug ? 0.06 : 0.008), now: now)
            walk.mix(Int64(windows.count))
            for w in windows { walk.visit(w) }
            return walk.spent ? nil : walk.hash
        }

        private struct Walk {
            let deadline: TimeInterval
            let now: () -> TimeInterval
            var budget = Fingerprints.maxNodes
            var spent = false
            var hash: Int64 = 1_125_899_906_842_597

            init(deadline: TimeInterval, now: @escaping () -> TimeInterval) {
                self.deadline = deadline
                self.now = now
            }

            mutating func mix(_ x: Int64) { hash = 31 &* hash &+ x }

            /// Text, by FNV-1a over its bytes: the same text mixes the same in every process.
            mutating func text(_ s: String?) {
                guard let s = s else { return mix(Int64(0)) }
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
                mix(Int64(bitPattern: h))
            }

            mutating func flag(_ b: Bool) { mix(Int64(b ? 1 : 2)) }

            mutating func number(_ d: CGFloat) { mix(Int64(bitPattern: Double(d).bitPattern)) }

            /// An object by its identity: an image, a layer's contents.
            mutating func object(_ o: AnyObject?) { mix(o.map { Int64(ObjectIdentifier($0).hashValue) } ?? Int64(0)) }

            /// Whether the budget is spent, by count, and every 64 views by time.
            mutating func spend() -> Bool {
                if spent { return true }
                budget -= 1
                if budget < 0 || (budget % 64 == 0 && now() > deadline) { spent = true }
                return spent
            }

            mutating func visit(_ v: UIView) {
                if spend() || v.isHidden || v.alpha <= 0.01 { return }
                if v is WKWebView { return }
                text(NSStringFromClass(type(of: v)))
                switch v {
                case let f as UITextField:
                    // What a visitor types is no answer, and a field draws it in views of its own.
                    flag(f.isEnabled)
                    return
                case let t as UITextView:
                    if t.isEditable { return }
                    text(t.text)
                case let l as UILabel:
                    text(l.text)
                case let i as UIImageView:
                    // Its image, never whether it is highlighted, which follows its cell's highlight as it is pressed.
                    object(i.image)
                case let s as UISwitch:
                    flag(s.isOn)
                    flag(s.isEnabled)
                case let s as UISegmentedControl:
                    mix(Int64(s.selectedSegmentIndex))
                    flag(s.isEnabled)
                case let s as UISlider:
                    number(CGFloat(s.value))
                case let s as UIStepper:
                    number(CGFloat(s.value))
                case let p as UIProgressView:
                    number(CGFloat(p.progress))
                case let p as UIPageControl:
                    mix(Int64(p.currentPage))
                case let a as UIActivityIndicatorView:
                    flag(a.isAnimating)
                case let c as UIControl:
                    flag(c.isSelected)
                    flag(c.isEnabled)
                default:
                    break
                }
                if let cell = v as? UITableViewCell { flag(cell.isSelected) }
                if let cell = v as? UICollectionViewCell { flag(cell.isSelected) }
                if let s = v as? UIScrollView {
                    number(s.contentOffset.x)
                    number(s.contentOffset.y)
                }
                // SwiftUI draws in layers its views name nothing of: where they are and what they hold.
                if TapResolver.swiftUIOwned(v) {
                    number(v.frame.origin.x)
                    number(v.frame.origin.y)
                    layers(v.layer)
                }
                for sub in v.subviews { visit(sub) }
            }

            /// A SwiftUI view's own layers, never another view's, which is visited as a view.
            mutating func layers(_ layer: CALayer) {
                for l in layer.sublayers ?? [] {
                    if l.delegate is UIView { continue }
                    if spend() { return }
                    if l.isHidden || l.opacity <= 0.01 { continue }
                    number(l.frame.origin.x)
                    number(l.frame.origin.y)
                    number(l.frame.size.width)
                    number(l.frame.size.height)
                    object(l.contents as AnyObject?)
                    layers(l)
                }
            }
        }
    }
#endif
