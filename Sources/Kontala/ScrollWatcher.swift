#if os(iOS)
    import Foundation
    import KontalaCore
    import UIKit
    import WebKit

    /// Scroll depth's side of the app's windows, on the main thread, the Android SDK's `ScrollWatcher`: the screen's
    /// scroll view, read through a 100 ms throttle as it scrolls, once the screen settles and as the app is hidden,
    /// each `Reading` told to the core, which keeps the depth and drops what is read during a navigation.
    ///
    /// The screen's scroll view is the largest one scrolling vertically that covers half the window both ways: a
    /// scroll view, a table or a collection view, SwiftUI's `ScrollView` and `List` among them, which are UIKit's
    /// underneath. Never a web view's own, or one inside a web view, whose content is the page's, which the page's tag
    /// measures. It is found as the screen settles, in the screen's view, and again under every finger that goes down,
    /// where a larger one is there, and followed by observing its offset and its content's size.
    ///
    /// A reading is in points: how far down the content the visible part ends, the content's height, and the visible
    /// height, each without the insets the bars and the home indicator take.
    final class ScrollWatcher {
        /// How often a scroll is read while it goes on, in seconds.
        static let throttle: TimeInterval = 0.1

        /// The most views looked at to find a screen's scroll view.
        static let budget = 3000

        var signals: MeasureSignals?

        /// Told as the screen's scroll view moves, which answers a tap.
        var moved: () -> Void = {}

        private let switches: Switches
        private let now: () -> TimeInterval
        private let after: (TimeInterval, @escaping () -> Void) -> Void

        private weak var screen: UIViewController?
        private weak var root: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var lastReading = -TimeInterval.greatestFiniteMagnitude
        private var throttled = false
        /// Which screen a settle was armed for: one armed for an earlier screen reads nothing.
        private var generation = 0

        /// [after] runs a block on the main thread after a delay.
        init(
            switches: Switches, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, f in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: f)
            }
        ) {
            self.switches = switches
            self.now = now
            self.after = after
        }

        /// A screen was shown: its scroll view is found anew, and read once it settles.
        func shown(_ vc: UIViewController) {
            screen = vc
            follow(nil)
            generation += 1
            guard let rules = switches.scrollRules else { return }
            let g = generation
            after(Double(rules.settleMs) / 1000) { [weak self] in
                guard let self = self, self.generation == g else { return }
                self.read()
            }
        }

        /// A finger went down: the largest vertical scroll view under it covering half the window becomes the
        /// screen's.
        func down(_ p: Pointer) {
            guard switches.scrollRules != nil, let view = screen?.viewIfLoaded, view.window === p.sample.window else {
                return
            }
            let size = p.sample.window.bounds.size
            var best: UIScrollView?
            var bestArea: CGFloat = 0
            for v in p.chain {
                // What is inside a web view is the page's.
                if v is WKWebView { break }
                guard let sv = v as? UIScrollView, ScrollWatcher.vertical(sv),
                    let area = ScrollWatcher.covering(sv, size), area > bestArea
                else { continue }
                best = sv
                bestArea = area
            }
            guard let b = best, b !== root else { return }
            if let current = root, current.window != nil,
                (ScrollWatcher.covering(current, size) ?? 0) > bestArea
            {
                return
            }
            follow(b)
        }

        /// The app is about to be said hidden: its last reading.
        func hiding() {
            if switches.scrollRules != nil && screen != nil { read() }
        }

        func stop() {
            generation += 1
            screen = nil
            follow(nil)
        }

        /// The scroll view followed moved or grew: read now, or at the end of the throttle.
        private func scrolled() {
            moved()
            guard switches.scrollRules != nil, screen != nil else { return }
            let t = now()
            if t - lastReading >= ScrollWatcher.throttle {
                read()
                return
            }
            if throttled { return }
            throttled = true
            after(ScrollWatcher.throttle - (t - lastReading)) { [weak self] in
                guard let self = self else { return }
                self.throttled = false
                self.read()
            }
        }

        private func follow(_ sv: UIScrollView?) {
            for o in observations { o.invalidate() }
            observations.removeAll()
            root = sv
            guard let s = sv else { return }
            observations = [
                s.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.onMain { $0.scrolled() } },
                s.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.onMain { $0.scrolled() } },
            ]
        }

        /// UIKit changes a scroll view on the main thread; a change from anywhere else is read there.
        private func onMain(_ f: @escaping (ScrollWatcher) -> Void) {
            if Thread.isMainThread {
                f(self)
            } else {
                DispatchQueue.main.async { [weak self] in
                    if let self = self { f(self) }
                }
            }
        }

        private func read() {
            guard switches.scrollRules != nil else { return }
            lastReading = now()
            guard let r = reading() else { return }
            signals?.scrolled(r)
        }

        /// A reading of the scroll view followed, else of the one the screen's view holds.
        private func reading() -> Reading? {
            guard let view = screen?.viewIfLoaded, let window = view.window else { return nil }
            if root == nil || root?.window !== window { follow(ScrollWatcher.find(in: view, window.bounds.size)) }
            return root.flatMap(ScrollWatcher.reading)
        }

        /// The largest vertical scroll view covering half the window, in [view] or [view] itself.
        static func find(in view: UIView, _ size: CGSize) -> UIScrollView? {
            var best: UIScrollView?
            var bestArea: CGFloat = 0
            var left = budget
            func visit(_ v: UIView) {
                left -= 1
                if left < 0 || v.isHidden || v.alpha <= 0.01 || v is WKWebView { return }
                if let sv = v as? UIScrollView, vertical(sv), let area = covering(sv, size), area > bestArea {
                    best = sv
                    bestArea = area
                }
                for sub in v.subviews { visit(sub) }
            }
            visit(view)
            return best
        }

        /// Whether [sv] scrolls vertically: a table does, and a collection laid out down the screen, whether or not
        /// its content fills it; another scroll view where its content is taller than it shows, or it bounces down.
        static func vertical(_ sv: UIScrollView) -> Bool {
            if !sv.isScrollEnabled { return false }
            if let t = sv as? UITextView { return !t.isEditable && overflows(sv) }
            if sv is UITableView { return true }
            if let cv = sv as? UICollectionView {
                if let flow = cv.collectionViewLayout as? UICollectionViewFlowLayout {
                    return flow.scrollDirection == .vertical
                }
                if let c = cv.collectionViewLayout as? UICollectionViewCompositionalLayout {
                    return c.configuration.scrollDirection == .vertical
                }
            }
            return sv.alwaysBounceVertical || overflows(sv)
        }

        private static func overflows(_ sv: UIScrollView) -> Bool {
            let inset = sv.adjustedContentInset
            return sv.contentSize.height + inset.top + inset.bottom > sv.bounds.height + 1
        }

        /// [sv]'s area where it covers half a window of [size] both ways, else nil.
        static func covering(_ sv: UIScrollView, _ size: CGSize) -> CGFloat? {
            let b = sv.bounds.size
            if b.width < size.width / 2 || b.height < size.height / 2 { return nil }
            return b.width * b.height
        }

        /// A scroll view's reading, in points: the bottom of what shows, the content's height, and how much shows,
        /// each inside its insets; the content is never shorter than what shows.
        static func reading(_ sv: UIScrollView) -> Reading? {
            let inset = sv.adjustedContentInset
            let viewport = sv.bounds.height - inset.top - inset.bottom
            if viewport <= 0 { return nil }
            let bottom = sv.contentOffset.y + sv.bounds.height - inset.bottom
            return Reading(Double(bottom), Double(max(sv.contentSize.height, viewport)), Double(viewport))
        }
    }
#endif
