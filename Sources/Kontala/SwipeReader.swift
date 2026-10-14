#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit
    import WebKit

    /// Swipes, read off a finger's touches on the main thread by the tag's rules, the Flutter SDK's
    /// (scroll/swipes.dart) and the Android SDK's, with the thresholds the property is served: one finger, at least the
    /// served distance and one and a half times more along its axis than across it, within the served time, not
    /// starting within the bands at either side where the back gesture starts, not on a field, a slider or a switch,
    /// and not in a web view, whose page reads its own.
    ///
    /// Its effect is `scrolled` when a scroll view under the finger moved along the swipe, a carousel, a pager or a
    /// list across the screen; `script` when, with no scroll view moving, a view under the finger moved along it, or a
    /// pan or a swipe recognizer of the app's took it, which is the app's own code dragging it, as a swipe to dismiss
    /// does; and `none` otherwise. A swipe across a scroll view that moved is scrolling, and none. It names the scroll
    /// view or the view that moved, else what a tap there would be on, never with its text, since a carousel's text
    /// is every slide's. SwiftUI moves what it draws in its own layers, so a drag of SwiftUI's is `none`.
    final class SwipeReader {
        var signals: MeasureSignals?
        private let switches: Switches

        /// Where a view was as the finger went down: a scroll view's offset, and its own place in its superview.
        private struct Mark {
            let scroller: Bool
            let offset: CGPoint
            let position: CGPoint
        }

        private struct Touch {
            let pointer: Pointer
            let marks: [Mark]
        }

        private var touch: Touch?

        init(switches: Switches) {
            self.switches = switches
        }

        /// A touch began: a finger's, which is what swipes.
        func down(_ p: Pointer) {
            touch = nil
            guard let rules = switches.scrollRules?.swipes, p.sample.input == "touch" else { return }
            let x = Double(p.sample.point.x)
            let width = Double(p.sample.window.bounds.width)
            if x < Double(rules.edgePx) || x > width - Double(rules.edgePx) { return }
            if p.chain.contains(where: { $0 is WKWebView || $0.kontalaIgnore }) { return }
            var marks: [Mark] = []
            for v in p.chain {
                if TapResolver.dragged(v) { return }
                let sv = v as? UIScrollView
                marks.append(
                    Mark(scroller: sv != nil, offset: sv?.contentOffset ?? .zero, position: SwipeReader.position(v)))
            }
            touch = Touch(pointer: p, marks: marks)
        }

        /// A second finger, or the gesture taken away: no swipe.
        func cancel() {
            touch = nil
        }

        /// The finger was lifted, before UIKit delivers it: whether it swiped, and what it did.
        func up(_ s: TouchSample) {
            guard let t = touch else { return }
            touch = nil
            guard let rules = switches.scrollRules?.swipes else { return }
            let start = t.pointer.sample
            let dx = Double(s.point.x - start.point.x)
            let dy = Double(s.point.y - start.point.y)
            let ms = Int64(((s.time - start.time) * 1000).rounded())
            let along = max(abs(dx), abs(dy))
            let across = min(abs(dx), abs(dy))
            if along < Double(rules.minPx) || along < rules.axisRatio * across || ms > Int64(rules.maxMs) { return }
            let horizontal = abs(dx) >= abs(dy)
            let direction = horizontal ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
            guard let (effect, target) = effectOf(t, horizontal), swipeCaptured(direction, effect) else { return }
            signals?.swiped(
                Swipe(
                    direction: direction, effect: effect, distance: Int64(along.rounded()), durationMs: ms,
                    target: target, x: Double(start.point.x), y: Double(start.point.y)))
        }

        /// What the swipe did and what it was on, or nil where it scrolled across itself, which is scrolling.
        private func effectOf(_ t: Touch, _ horizontal: Bool) -> (String, TapTarget)? {
            let chain = t.pointer.chain
            var along: Int?
            for (i, m) in t.marks.enumerated() where m.scroller {
                guard let sv = chain[i] as? UIScrollView else { continue }
                let dh = abs(sv.contentOffset.x - m.offset.x)
                let dv = abs(sv.contentOffset.y - m.offset.y)
                // Less than a point is no scroll.
                if dh < 1 && dv < 1 { continue }
                if (dh >= dv) != horizontal { return nil }
                if along == nil { along = i }
            }
            if let i = along { return ("scrolled", TapResolver.describe(chain, i, role: "other")) }
            for (i, m) in t.marks.enumerated() {
                let now = SwipeReader.position(chain[i])
                let own = horizontal ? now.x - m.position.x : now.y - m.position.y
                if abs(own) >= 1 { return ("script", TapResolver.describe(chain, i, role: "other")) }
            }
            if let i = chain.lastIndex(where: SwipeReader.dragging) {
                return ("script", TapResolver.describe(chain, i, role: "other"))
            }
            guard let target = t.pointer.resolution.target?.target ?? TapResolver.describeHit(chain) else {
                return nil
            }
            return ("none", target)
        }

        /// Where a view is in its superview, its transform's move included, as a swipe to dismiss moves one.
        private static func position(_ v: UIView) -> CGPoint {
            CGPoint(x: v.center.x + v.transform.tx, y: v.center.y + v.transform.ty)
        }

        /// Whether a pan or a swipe recognizer of the app's on [v] took the finger.
        private static func dragging(_ v: UIView) -> Bool {
            (v.gestureRecognizers ?? []).contains { g in
                guard g.isEnabled, g is UIPanGestureRecognizer || g is UISwipeGestureRecognizer else { return false }
                let cls: AnyClass = type(of: g)
                let own =
                    cls == UIPanGestureRecognizer.self || cls == UISwipeGestureRecognizer.self
                    || !TapResolver.isSystem(cls)
                return own && (g.state == .began || g.state == .changed || g.state == .ended)
            }
        }
    }
#endif
