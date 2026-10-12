#if os(iOS)
    import Foundation
    import KontalaCore
    import ObjectiveC
    import UIKit

    /// What the screen watcher tells: the core, through its queue, or a test's record.
    protocol ScreenSignals: AnyObject {
        /// A navigation began, at its first sign, before anything of the next screen.
        func begin(_ kind: NavigationKind)

        /// A screen is on show, named as its source names it, or nil where it names none.
        func shown(
            _ raw: String?, _ kind: NavigationKind, _ declaration: ScreenDeclaration?, _ route: RouteRef,
            _ title: String?)

        /// What a screen on show declares changed, as a SwiftUI screen's data that arrives after it is shown.
        func declared(_ route: RouteRef, _ declaration: ScreenDeclaration)

        /// A screen or a dialog opened or closed: an answer to a tap.
        func routeChanged()

        /// The launch's first screen was read: a launch nothing named is filed as `/`.
        func firstFrame()
    }

    /// The core as the screen watcher tells it, through its queue: what reaches the queue is the view controller's weak
    /// reference, never the view controller.
    final class CoreScreenSignals: ScreenSignals {
        private let running: Kontala.Running

        init(_ running: Kontala.Running) {
            self.running = running
        }

        func begin(_ kind: NavigationKind) { running.post { $0.hub.begin(kind) } }

        func shown(
            _ raw: String?, _ kind: NavigationKind, _ declaration: ScreenDeclaration?, _ route: RouteRef,
            _ title: String?
        ) {
            running.post { $0.hub.shown(raw, kind, declaration: declaration, route: route, title: title) }
        }

        func declared(_ route: RouteRef, _ declaration: ScreenDeclaration) {
            running.post { $0.screens.declared(route, declaration) }
        }

        func routeChanged() { running.post { $0.routeChanged() } }

        func firstFrame() { running.post { $0.firstFrame() } }
    }

    /// A screen as a view controller names it: what it is, its name where it has one, what it declares and the title
    /// it shows.
    struct Candidate {
        let route: UIViewController
        let raw: String?
        let declaration: ScreenDeclaration?
        let title: String?
    }

    /// The screens of a native app, the Flutter SDK's navigator observers for UIKit's view controllers and the hosting
    /// controllers SwiftUI shows its screens in, on the main thread.
    ///
    /// A navigation is told to the core at its first sign: a view controller loading its view, before the app's own
    /// code in its `viewDidLoad` can declare a page type, which then rides on the screen it opens; one shown again, as
    /// a pop or a tab switch shows one; or one popped or dismissed. Its screen is read at the frame after a view
    /// controller appeared or one left, once no transition is in flight, and told as a navigation's screen, or as a
    /// change where nothing began one.
    ///
    /// The screen is the front one: down from the key window's root, through what is presented, a navigation
    /// controller's top, a tab bar controller's selection, a split view's last column and a page view's page, to a
    /// child view controller that fills at least half its parent, as a SwiftUI navigation stack does its root's. An
    /// alert, a popover, a sheet at medium height alone and a system view controller presented, a share sheet or a
    /// picker, are no screen: a tap in one is filed under the screen beneath, and each opening and closing is an
    /// answer to a tap. A return from the background is no navigation, and calls none of these.
    final class ScreenWatcher {
        /// The watcher the view controllers' swizzled methods report to, on the main thread.
        ///
        /// The watcher it replaces is let go of only once the write is over: releasing it can release a window, whose
        /// view controllers UIKit then tells they disappear, whose hooks read this very property, which Swift traps
        /// as a read during the write (measured on the simulator).
        static var current: ScreenWatcher? {
            get { installed }
            set {
                let old = installed
                installed = newValue
                withExtendedLifetime(old) {}
            }
        }

        private static var installed: ScreenWatcher?

        let signals: ScreenSignals
        private let window: () -> UIWindow?
        private let nextFrame: (@escaping () -> Void) -> Void
        private let inFlight: (UIViewController) -> Bool

        /// Writes a line of the SDK's debug log.
        var warn: (String) -> Void = { _ in }

        private var begun = false
        private var kind: NavigationKind?
        private var scheduled = false
        private var framed = false
        private var fallbackArmed = false
        private weak var lastRoute: UIViewController?
        private var lastRaw: String?
        private let tabs = NSMapTable<UITabBarController, UIViewController>.weakToWeakObjects()

        /// [inFlight] says whether a view controller is in a transition: UIKit's own coordinator, unless a test with
        /// no application, where UIKit never ends some it starts, says otherwise.
        init(
            signals: ScreenSignals, window: @escaping () -> UIWindow?,
            nextFrame: @escaping (@escaping () -> Void) -> Void = NextFrame.after,
            inFlight: @escaping (UIViewController) -> Bool = { $0.transitionCoordinator != nil }
        ) {
            self.signals = signals
            self.window = window
            self.nextFrame = nextFrame
            self.inFlight = inFlight
        }

        // What the view controllers' own methods say, with what UIKit says of the transition each is in.

        /// A view controller loaded its view: a pushed or presented screen's first sign.
        func loaded(_ vc: UIViewController) {
            guard ScreenKinds.content(vc) else { return }
            begin(tabSwitch(vc) ?? .push)
        }

        /// A view controller will appear: [arriving] when it is pushed or presented, rather than shown again.
        func willAppear(_ vc: UIViewController, arriving: Bool) {
            if ScreenKinds.dialog(vc) {
                signals.routeChanged()
                return
            }
            guard ScreenKinds.content(vc) || (arriving && ScreenKinds.container(vc)) else { return }
            begin(tabSwitch(vc) ?? (arriving ? .push : .pop))
        }

        func didAppear(_ vc: UIViewController) {
            if ScreenKinds.dialog(vc) { return }
            schedule()
        }

        /// A view controller will disappear: [leaving] when it is popped or dismissed, rather than covered.
        func willDisappear(_ vc: UIViewController, leaving: Bool) {
            if !leaving || ScreenKinds.dialog(vc) { return }
            if ScreenKinds.content(vc) || ScreenKinds.container(vc) { begin(.pop) }
        }

        func didDisappear(_ vc: UIViewController, leaving: Bool) {
            if ScreenKinds.dialog(vc) {
                signals.routeChanged()
                return
            }
            // The screen beneath a sheet is never told it appears again: its read follows the sheet's going.
            if leaving { schedule() }
        }

        /// What a SwiftUI screen declares changed: the screen view of the screen on show takes it while it is unsent.
        func declarationChanged(_ vc: UIViewController, _ d: ScreenDeclaration) {
            if lastRoute === vc { signals.declared(RouteRef(vc), d) }
        }

        /// A tab bar controller's selection that changed since it was last read, which a screen shown in it opens as
        /// a tab switch.
        private func tabSwitch(_ vc: UIViewController) -> NavigationKind? {
            guard let tab = vc.tabBarController, let selected = tab.selectedViewController else { return nil }
            if tabs.object(forKey: tab) === selected { return nil }
            tabs.setObject(selected, forKey: tab)
            return .tab
        }

        /// A navigation began: its first sign is told, and every later one until its screen is read is the same
        /// navigation, as a view controller and the children it loads are.
        private func begin(_ k: NavigationKind) {
            if begun { return }
            begun = true
            kind = k
            signals.begin(k)
            // A navigation that shows nothing new, a view loaded and never shown, is settled at the next frame.
            schedule()
        }

        /// Reads the screen at the next frame, once everything of it has said what it is.
        func schedule() {
            if scheduled { return }
            scheduled = true
            nextFrame { [weak self] in self?.dispatch() }
        }

        private func dispatch() {
            scheduled = false
            guard let root = window()?.rootViewController else { return }
            let chain = ScreenKinds.front(root)
            if chain.contains(where: inFlight) {
                // A transition in flight: its end appears or disappears something, which reads again.
                armFallback()
                return
            }
            if let vc = chain.last {
                let c = candidate(vc)
                let same = lastRoute === c.route && lastRaw == c.raw
                if begun || !same {
                    lastRoute = c.route
                    lastRaw = c.raw
                    signals.shown(c.raw, kind ?? .push, c.declaration, RouteRef(c.route), c.title)
                }
            }
            begun = false
            kind = nil
            if !framed {
                framed = true
                signals.firstFrame()
            }
        }

        /// Reads again a second on, for a transition whose end no view controller says.
        private func armFallback() {
            if fallbackArmed { return }
            fallbackArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self else { return }
                self.fallbackArmed = false
                self.schedule()
            }
        }

        func candidate(_ vc: UIViewController) -> Candidate {
            let d = ScreenNames.declaration(vc)
            let title = ScreenNames.title(vc)
            let raw = d?.name ?? ScreenNames.className(vc) ?? title
            return Candidate(route: vc, raw: raw, declaration: d, title: title)
        }

        /// The key window of the app's scene in front.
        static func keyWindow() -> UIWindow? {
            guard let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication else { return nil }
            let scenes = app.connectedScenes.compactMap { $0 as? UIWindowScene }
            for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
                for scene in scenes where scene.activationState == state {
                    if let w = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first { return w }
                }
            }
            return nil
        }
    }

    /// Which view controllers are screens, containers and dialogs, and which one is in front.
    enum ScreenKinds {
        /// The view controllers from the key window's root to the screen in front, that one last.
        static func front(_ root: UIViewController) -> [UIViewController] {
            var chain = [root]
            var vc = root
            for _ in 0..<32 {
                let next: UIViewController?
                if let p = vc.presentedViewController, !p.isBeingDismissed, !dialog(p) {
                    next = p
                } else if let nav = vc as? UINavigationController {
                    next = nav.topViewController
                } else if let tab = vc as? UITabBarController {
                    next = tab.selectedViewController
                } else if let split = vc as? UISplitViewController {
                    next = split.viewControllers.last
                } else if let page = vc as? UIPageViewController {
                    next = page.viewControllers?.first
                } else {
                    next = filling(vc)
                }
                guard let n = next, n !== vc else { break }
                chain.append(n)
                vc = n
            }
            return chain
        }

        /// The child of [vc] whose view fills at least half of [vc]'s, the last added first: a SwiftUI root's
        /// navigation stack, or a container of the app's own. A mini player, a banner or any part of a screen is no
        /// screen.
        static func filling(_ vc: UIViewController) -> UIViewController? {
            guard vc.isViewLoaded, vc.view.window != nil else { return nil }
            let area = vc.view.bounds.width * vc.view.bounds.height
            for child in vc.children.reversed() {
                guard child.isViewLoaded, let v = child.view, v.window != nil, visible(v) else { continue }
                if system(child) && !swiftUIHost(child) && !container(child) { continue }
                if area > 0 && v.bounds.width * v.bounds.height * 2 < area { continue }
                return child
            }
            return nil
        }

        /// Whether [v] and every view it is in is on show.
        static func visible(_ v: UIView) -> Bool {
            var x: UIView? = v
            while let view = x {
                if view.isHidden || view.alpha <= 0.01 { return false }
                x = view.superview
            }
            return true
        }

        /// UIKit's containers, which show screens rather than being one.
        static func container(_ vc: UIViewController) -> Bool {
            vc is UINavigationController || vc is UITabBarController || vc is UISplitViewController
                || vc is UIPageViewController
        }

        /// A view controller that may be a screen: the app's own, a hosting controller SwiftUI shows a screen in, or a
        /// plain view controller the app filled; never a container, a dialog, or UIKit's own, such as the keyboard's.
        static func content(_ vc: UIViewController) -> Bool {
            if container(vc) || dialog(vc) { return false }
            if type(of: vc) == UIViewController.self || swiftUIHost(vc) { return true }
            return !system(vc)
        }

        /// A dialog over the screen: an alert, a popover, a sheet at medium height alone, or a view controller of the
        /// system's presented over the app's, as a share sheet, a picker and a search controller are.
        static func dialog(_ vc: UIViewController) -> Bool {
            if vc is UIAlertController { return true }
            guard vc.presentingViewController != nil else { return false }
            if vc.modalPresentationStyle == .popover { return true }
            if #available(iOS 16, *),
                vc.modalPresentationStyle == .pageSheet || vc.modalPresentationStyle == .formSheet,
                let sheet = vc.sheetPresentationController, !sheet.detents.isEmpty,
                sheet.detents.allSatisfy({ $0.identifier == .medium })
            {
                return true
            }
            return system(vc) && !swiftUIHost(vc) && !container(vc) && type(of: vc) != UIViewController.self
        }

        /// Whether [vc]'s class is one of the system's frameworks', rather than the app's.
        static func system(_ vc: UIViewController) -> Bool { fromSystem(type(of: vc)) }

        static func fromSystem(_ cls: AnyClass) -> Bool {
            Bundle(for: cls).bundlePath.contains("/System/Library/")
        }

        /// A hosting controller SwiftUI shows a screen in, or an app's own subclass of one.
        static func swiftUIHost(_ vc: UIViewController) -> Bool {
            var c: AnyClass? = type(of: vc)
            while let k = c, k != UIViewController.self {
                if NSStringFromClass(k).contains("HostingController") && fromSystem(k) { return true }
                c = class_getSuperclass(k)
            }
            return false
        }
    }

    /// How a view controller names its screen: what it declares, its class, the title it shows.
    enum ScreenNames {
        /// What [vc] declares about its screen, through `KontalaScreen` or SwiftUI's `.kontalaScreen`.
        static func declaration(_ vc: UIViewController) -> ScreenDeclaration? {
            if let s = vc as? KontalaScreen {
                let props = s.kontalaScreenProperties.flatMap { jsonSafe($0)?.object }
                let d = ScreenDeclaration(name: s.kontalaScreenName, pageType: s.kontalaPageType, properties: props)
                if d.name != nil || d.pageType != nil || d.properties != nil { return d }
            }
            return ScreenDeclarations.of(vc)
        }

        /// A class's own name, `ProductViewController`, or nil for one of the system's, which names no screen of the
        /// app's: a plain view controller, or a hosting controller SwiftUI made.
        static func className(_ vc: UIViewController) -> String? {
            let cls: AnyClass = type(of: vc)
            if ScreenKinds.fromSystem(cls) { return nil }
            let full = String(describing: cls)
            let name = full.split(separator: "<").first.map(String.init) ?? full
            return name.isEmpty ? nil : name
        }

        /// The title the screen shows: its navigation item's, else its own, where that is neither blank nor its class's
        /// name.
        static func title(_ vc: UIViewController) -> String? {
            for t in [vc.navigationItem.title, vc.title] {
                guard let s = t?.trimmingCharacters(in: .whitespacesAndNewlines), !blank(s) else { continue }
                if s == String(describing: type(of: vc)) { continue }
                return s
            }
            return nil
        }

        /// Whether a title says nothing: empty, or, as UIKit gives a navigation item the blank title of its view
        /// controller, nothing but whitespace in curly quotes (“  ”), measured on iOS 18.6.
        private static func blank(_ s: String) -> Bool {
            if s.isEmpty { return true }
            guard s.count >= 2, s.first == "\u{201C}", s.last == "\u{201D}" else { return false }
            return s.dropFirst().dropLast().allSatisfy { $0.isWhitespace }
        }
    }

    /// The view controllers' appearance methods, swizzled once to tell the screen watcher, after each has run, and
    /// changing nothing of what they do: every view controller's own override reaches them through `super`.
    enum UIKitHooks {
        static let installed: Void = {
            swap(#selector(UIViewController.viewDidLoad), #selector(UIViewController.kontalaViewDidLoad))
            swap(
                #selector(UIViewController.viewWillAppear(_:)), #selector(UIViewController.kontalaViewWillAppear(_:)))
            swap(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.kontalaViewDidAppear(_:)))
            swap(
                #selector(UIViewController.viewWillDisappear(_:)),
                #selector(UIViewController.kontalaViewWillDisappear(_:)))
            swap(
                #selector(UIViewController.viewDidDisappear(_:)),
                #selector(UIViewController.kontalaViewDidDisappear(_:)))
        }()

        private static func swap(_ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(UIViewController.self, original),
                let b = class_getInstanceMethod(UIViewController.self, replacement)
            else { return }
            method_exchangeImplementations(a, b)
        }
    }

    extension UIViewController {
        // Each calls what it replaced, which after the exchange is its own selector, and then tells the watcher. They
        // are `dynamic` so that call goes through the runtime: called directly, as an optimised build may call a method
        // nothing can override, each would call itself.

        @objc(kontala_viewDidLoad) fileprivate dynamic func kontalaViewDidLoad() {
            kontalaViewDidLoad()
            ScreenWatcher.current?.loaded(self)
        }

        @objc(kontala_viewWillAppear:) fileprivate dynamic func kontalaViewWillAppear(_ animated: Bool) {
            kontalaViewWillAppear(animated)
            ScreenWatcher.current?.willAppear(self, arriving: isMovingToParent || isBeingPresented)
        }

        @objc(kontala_viewDidAppear:) fileprivate dynamic func kontalaViewDidAppear(_ animated: Bool) {
            kontalaViewDidAppear(animated)
            ScreenWatcher.current?.didAppear(self)
        }

        @objc(kontala_viewWillDisappear:) fileprivate dynamic func kontalaViewWillDisappear(_ animated: Bool) {
            kontalaViewWillDisappear(animated)
            ScreenWatcher.current?.willDisappear(self, leaving: isMovingFromParent || isBeingDismissed)
        }

        @objc(kontala_viewDidDisappear:) fileprivate dynamic func kontalaViewDidDisappear(_ animated: Bool) {
            kontalaViewDidDisappear(animated)
            ScreenWatcher.current?.didDisappear(self, leaving: isMovingFromParent || isBeingDismissed)
        }
    }
#endif
