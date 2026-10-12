#if os(iOS)
    import Foundation
    import KontalaCore
    import ObjectiveC
    import UIKit
    import WebKit

    /// What a press resolved to: the control it acted on, as the Flutter SDK's `resolveTap` answers.
    enum TapResolution {
        /// Under `kontalaIgnore`, or on a web view, whose page reads its own: nothing is captured.
        case ignored
        /// No control: a press on the screen's background, or on a SwiftUI control nothing marks.
        case none
        case target(ResolvedTarget)

        var target: ResolvedTarget? {
            if case .target(let t) = self { return t }
            return nil
        }
    }

    struct ResolvedTarget {
        let target: TapTarget
        /// The views from the window down to the control, or to the SwiftUI mark it is read off.
        let chain: [UIView]
        /// The control's index in [chain].
        let index: Int
        /// The field, where the control is one.
        let field: UIView?

        var control: UIView { chain[index] }
    }

    /// Reads a tap off an app's views, on the main thread, by the Flutter SDK's rules for its widgets
    /// (tree/resolve.dart, plugins/forms.dart) as the Android SDK reads them off its views: a control is a view that
    /// acts on a tap, its role is what UIKit says it is, its id its accessibility identifier, its label its
    /// accessibility label or a field's placeholder, and its text what it shows, never a field's, a choice's or a
    /// nested control's. An identifier and a label are only ever what the app set (`appIdentifier`, `appLabel`).
    ///
    /// SwiftUI draws its own controls, so a press on one reaches only SwiftUI's views, which name nothing: it is read
    /// off the SwiftUI marks on show (`TapMarks`), and a SwiftUI control nothing marks is no control. Its UIKit
    /// controls, a field, a switch, a bar's buttons, are found as UIKit's are.
    ///
    /// Every walk has a budget, since it runs on every press.
    enum TapResolver {
        /// The views from [view]'s window down to [view].
        static func chain(to view: UIView) -> [UIView] {
            var out: [UIView] = []
            var v: UIView? = view
            while let x = v, out.count < 300 {
                out.append(x)
                v = x.superview
            }
            return out.reversed()
        }

        /// What a press at [point] in the window, on the view UIKit gave it to, the last of [chain], acted on. A key's
        /// press has no point.
        static func resolve(_ chain: [UIView], at point: CGPoint?, captureText: Bool) -> TapResolution {
            guard let leaf = chain.last, let window = leaf.window else { return .none }
            if chain.contains(where: { $0 is WKWebView || $0.kontalaIgnore }) { return .ignored }
            let marks = point.map { TapMarks.at($0, in: window) } ?? []
            if marks.contains(where: { $0.kind == .ignore }) { return .ignored }
            let marked = Marked(marks)
            var disabled: Int?
            for i in stride(from: chain.count - 1, through: 0, by: -1) {
                let v = chain[i]
                // SwiftUI's own views: a control of its own is told by its marks alone.
                if swiftUIOwned(v) { break }
                if isField(v) {
                    return .target(
                        target(chain, i, fieldRole(v, chain, i), !fieldEnabled(v), captureText, marked, field: v))
                }
                // A drag control, as Flutter's Slider is no tap.
                if v is UISlider { return .none }
                if let tv = v as? UITextView, let p = point, let link = linkAt(tv, p) {
                    let t = target(chain, i, "link", false, captureText, marked, field: nil)
                    var tt = t.target
                    if !tt.masked {
                        tt.link = link.url
                        // The link's own text, as the web's `<a>` is, rather than the whole text view's.
                        if captureText { tt.text = link.text }
                    }
                    return .target(ResolvedTarget(target: tt, chain: chain, index: i, field: nil))
                }
                guard let role = roleOf(v, chain, i) else { continue }
                // A disabled control passes the press on to an enabled one around it, a cell or a card a recognizer
                // reads: the tap is theirs, and the disabled control's only where there is none. UIKit's own hit test
                // passes over a disabled control (measured on iOS 18.6), so a touch reaches this only through a
                // control nested in it; a key's focused control comes here as it is.
                if let c = v as? UIControl, !c.isEnabled {
                    if disabled == nil { disabled = i }
                    continue
                }
                return .target(target(chain, i, role, false, captureText, marked, field: nil))
            }
            if let d = disabled, let role = roleOf(chain[d], chain, d) {
                return .target(target(chain, d, role, true, captureText, marked, field: nil))
            }
            if let mark = marked.event { return .target(markTarget(mark, marked)) }
            return .none
        }

        /// What the SwiftUI marks under a press say: ignored is told before any of this.
        struct Marked {
            let masked: Bool
            let event: TapMarkView?

            init(_ marks: [TapMarkView]) {
                masked = marks.contains { $0.kind == .mask }
                event = marks.first { if case .event = $0.kind { return true } else { return false } }
            }

            var declared: KontalaClickType? {
                if case .event(let t, _, _)? = event?.kind { return t }
                return nil
            }

            var id: String? {
                if case .event(_, let id, _)? = event?.kind { return id }
                return nil
            }

            var label: String? {
                if case .event(_, _, let label)? = event?.kind { return label }
                return nil
            }
        }

        /// A SwiftUI control, read off its mark: a button, with the click type, id and label the mark gives.
        private static func markTarget(_ mark: TapMarkView, _ marked: Marked) -> ResolvedTarget {
            let chain = chain(to: mark)
            guard case .event(let type, let id, let label) = mark.kind else {
                return ResolvedTarget(
                    target: TapTarget(role: "button"), chain: chain, index: chain.count - 1, field: nil)
            }
            let masked = marked.masked || chain.contains { $0.kontalaMask }
            let owner = ownerName(of: mark)
            var t = TapTarget(
                role: "button", masked: masked, declared: type ?? chain.lazy.compactMap { $0.kontalaEvent }.last)
            if !masked {
                t.id = clean(id).map { cutBytes($0, Limits.maxAttribute) }
                t.label = clean(label).map { cutBytes(collapse($0, Limits.maxText), Limits.maxAttribute) }
            }
            t.path = owner
            t.region = regionOf(chain, chain.count - 1, mark)
            return ResolvedTarget(target: t, chain: chain, index: chain.count - 1, field: nil)
        }

        // What is what.

        static func isField(_ v: UIView) -> Bool {
            v is UITextField || ((v as? UITextView)?.isEditable ?? false)
        }

        private static func fieldEnabled(_ v: UIView) -> Bool {
            if let t = v as? UITextField { return t.isEnabled && t.isUserInteractionEnabled }
            return v.isUserInteractionEnabled
        }

        /// Whether a view is SwiftUI's own, which a press on one of its controls reaches.
        static func swiftUIOwned(_ v: UIView) -> Bool {
            let n = String(reflecting: type(of: v))
            return n.hasPrefix("SwiftUI.") || n.hasPrefix("SwiftUICore.")
        }

        /// Whether a class is one of the system's frameworks', rather than the app's.
        static func isSystem(_ cls: AnyClass) -> Bool {
            if ScreenKinds.fromSystem(cls) { return true }
            let n = String(reflecting: cls)
            return n.hasPrefix("SwiftUI.") || n.hasPrefix("SwiftUICore.") || n.hasPrefix("UIKit.")
        }

        /// Whether a view's class is the app's own: not the system's, and not this SDK's.
        static func appView(_ v: UIView) -> Bool {
            let cls: AnyClass = type(of: v)
            return !isSystem(cls) && !String(reflecting: cls).hasPrefix("Kontala.")
        }

        /// A gesture recognizer the app added, rather than one UIKit adds to its own views.
        private static func appRecognizer(_ g: UIGestureRecognizer) -> Bool {
            if !g.isEnabled { return false }
            let cls: AnyClass = type(of: g)
            if cls == UITapGestureRecognizer.self || cls == UILongPressGestureRecognizer.self { return true }
            return !isSystem(cls) && (g is UITapGestureRecognizer || g is UILongPressGestureRecognizer)
        }

        /// The plain UIKit views an app adds a tap recognizer to; UIKit's own views add their own, a sheet's dimming
        /// view to close it among them, which are no control of the app's.
        private static let plainViews: [AnyClass] = [UIView.self, UIImageView.self, UILabel.self, UIStackView.self]

        /// Whether the app listens for taps on [v] itself, through a recognizer of its own on a view of its own or a
        /// plain one.
        static func listens(_ v: UIView) -> Bool {
            let cls: AnyClass = type(of: v)
            guard appView(v) || plainViews.contains(where: { $0 == cls }) else { return false }
            return (v.gestureRecognizers ?? []).contains(where: appRecognizer)
        }

        /// Whether a press on [v] that is held is a long press, which no tap follows: a recognizer of the app's for
        /// one, or a context menu.
        static func longPress(_ v: UIView) -> TimeInterval? {
            for g in v.gestureRecognizers ?? [] {
                if let l = g as? UILongPressGestureRecognizer, l.isEnabled, appRecognizer(l) {
                    return l.minimumPressDuration
                }
            }
            if v.interactions.contains(where: { $0 is UIContextMenuInteraction }) { return 0.5 }
            return nil
        }

        /// A control's role, or nil for a view that is no control.
        static func roleOf(_ v: UIView, _ chain: [UIView], _ i: Int) -> String? {
            if v is UISwitch { return "switch" }
            if v is UISegmentedControl { return "radio" }
            if v is UIControl {
                return within(chain, i, 3, { $0 is UITabBar }) ? "tab" : "button"
            }
            if (v is UITableViewCell || v is UICollectionViewCell) && selectable(v) { return "cell" }
            if listens(v) { return v is UIImageView ? "image" : "button" }
            return nil
        }

        /// Whether the table or collection view holding a cell lets its cells be selected.
        private static func selectable(_ cell: UIView) -> Bool {
            var p = cell.superview
            while let s = p {
                if let t = s as? UITableView { return t.allowsSelection }
                if let c = s as? UICollectionView { return c.allowsSelection }
                p = s.superview
            }
            return false
        }

        /// Whether one of the [n] views above [i] in [chain] is [f]'s.
        private static func within(_ chain: [UIView], _ i: Int, _ n: Int, _ f: (UIView) -> Bool) -> Bool {
            var j = i - 1
            while j >= 0 && j >= i - n {
                if f(chain[j]) { return true }
                j -= 1
            }
            return false
        }

        private static func fieldRole(_ f: UIView, _ chain: [UIView], _ i: Int) -> String {
            searchField(f, chain, i) ? "searchbox" : "textbox"
        }

        private static func searchField(_ f: UIView, _ chain: [UIView], _ i: Int) -> Bool {
            if f is UISearchTextField { return true }
            if let t = f as? UITextField, t.returnKeyType == .search || t.keyboardType == .webSearch { return true }
            if within(chain, i, 6, { $0 is UISearchBar }) { return true }
            return fieldLabel(f)?.lowercased().contains("search") ?? false
        }

        // What a control says.

        private static func clean(_ s: String?) -> String? {
            guard let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }

        private typealias StringGetter = @convention(c) (NSObject, Selector) -> NSString?

        private static func getter(_ cls: AnyClass, _ name: String) -> (StringGetter, Selector)? {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { return nil }
            return (unsafeBitCast(method_getImplementation(m), to: StringGetter.self), sel)
        }

        /// NSObject's own `accessibilityLabel` and UIView's own `accessibilityIdentifier`, read before anything
        /// replaces them, which answer what the app set and nothing else.
        private static let labelGetter = getter(NSObject.self, "accessibilityLabel")
        private static let identifierGetter = getter(UIView.self, "accessibilityIdentifier")

        /// The accessibility label the app set on [o], never one UIKit makes up. While an assistive technology is on,
        /// VoiceOver, Voice Control, Switch Control or Full Keyboard Access, or XCUITest drives the app, UIKit's
        /// accessibility bundle answers `accessibilityLabel` with a button's title, a label's text and an icon's name
        /// ("love" for SF Symbols' heart), so a row would say whether its visitor uses one; NSObject's own
        /// implementation, which those answers come after, answers only what the app set (measured on iOS 18.6, with
        /// and without accessibility on).
        static func appLabel(_ o: NSObject) -> String? {
            guard let (f, sel) = labelGetter else { return nil }
            return f(o, sel) as String?
        }

        /// The accessibility identifier the app set on [v], never one UIKit makes up for its own views while
        /// accessibility is on, as a navigation bar's title and "BackButton" for its back button are.
        static func appIdentifier(_ v: UIView) -> String? {
            guard let (f, sel) = identifierGetter else { return nil }
            return f(v, sel) as String?
        }

        /// Whether [v] is a UIKit view SwiftUI shows, as a `TextField`'s field and a `Toggle`'s switch are: one whose
        /// nearest view controller is a hosting controller. SwiftUI hands such a view the identifier and the label its
        /// view declares only once something has read its accessibility tree, which an assistive technology does, so
        /// neither is read off it, and a mark says what it is instead. On iOS 18.6 a `TextField`'s
        /// `.accessibilityIdentifier` reached its field once XCUITest had read the screen, and not in seconds without
        /// it. A UIKit screen SwiftUI shows has a view controller of its own, so its views keep theirs.
        static func madeBySwiftUI(_ v: UIView) -> Bool {
            viewController(of: v).map(ScreenKinds.swiftUIHost) ?? false
        }

        private static func target(
            _ chain: [UIView], _ index: Int, _ role: String, _ disabled: Bool, _ captureText: Bool, _ marked: Marked,
            field: UIView?
        ) -> ResolvedTarget {
            var masked = marked.masked
            var declared: KontalaClickType?
            for i in stride(from: index, through: 0, by: -1) {
                if chain[i].kontalaMask { masked = true }
                if declared == nil { declared = chain[i].kontalaEvent }
            }
            if declared == nil { declared = marked.declared }
            let control = chain[index]
            let isField = role == "textbox" || role == "searchbox"
            let isChoice = role == "checkbox" || role == "radio" || role == "switch" || role == "option"
            var t = TapTarget(role: role, disabled: disabled, masked: masked, declared: declared)
            let uikits = labelledByUIKit(chain, index)
            let swiftUI = madeBySwiftUI(control)
            if !masked {
                if !isChoice && swiftUI {
                    // What a mark gives, as for SwiftUI's own controls, else a field's placeholder.
                    t.id = clean(marked.id).map { cutBytes($0, Limits.maxAttribute) }
                    t.label = clean(marked.label ?? (isField ? fieldLabel(control) : nil)).map {
                        cutBytes(collapse($0, Limits.maxText), Limits.maxAttribute)
                    }
                } else if !isChoice {
                    t.id = idOf(chain, index)
                    t.label = labelOf(chain, index, isField, uikits: uikits)
                }
                if !isField && !isChoice && captureText {
                    t.text = textOf(control, chain, imageLabels: !uikits && !swiftUI)
                }
                t.className = classNameOf(chain, index)
            }
            t.path = pathOf(chain, index, masked, ownerName(of: control))
            t.region = regionOf(chain, index, control)
            return ResolvedTarget(target: t, chain: chain, index: index, field: field)
        }

        /// The accessibility identifier of the control, else of a view inside it on the path pressed.
        private static func idOf(_ chain: [UIView], _ index: Int) -> String? {
            for i in index..<chain.count {
                if let id = clean(appIdentifier(chain[i])) { return cutBytes(id, Limits.maxAttribute) }
            }
            return nil
        }

        private static func labelOf(_ chain: [UIView], _ index: Int, _ isField: Bool, uikits: Bool) -> String? {
            func fit(_ s: String?) -> String? {
                clean(s).map { cutBytes(collapse($0, Limits.maxText), Limits.maxAttribute) }
            }
            if !uikits {
                for i in index..<min(chain.count, index + 40) {
                    if let l = fit(appLabel(chain[i])) { return l }
                }
            }
            if isField { return fit(fieldLabel(chain[index])) }
            return nil
        }

        /// Whether a control is one UIKit labels itself while an assistive technology is on, so that no label on it
        /// or in it is the app's: one in a navigation bar, a tab bar or a toolbar, whose buttons and titles UIKit's
        /// accessibility code gives their titles as labels, or one of UIKit's private controls, a field's clear button
        /// among them. On iOS 18.6 a back button read "Shop" and a tab "Account" with accessibility on, and nothing
        /// without it, even through `appLabel`.
        static func labelledByUIKit(_ chain: [UIView], _ index: Int) -> Bool {
            let cls: AnyClass = type(of: chain[index])
            if isSystem(cls) && NSStringFromClass(cls).hasPrefix("_") { return true }
            return chain[...index].contains { $0 is UINavigationBar || $0 is UITabBar || $0 is UIToolbar }
        }

        /// A field's label: its placeholder, else an accessibility label the app gave it.
        static func fieldLabel(_ f: UIView) -> String? {
            if let t = f as? UITextField {
                if let p = clean(t.placeholder ?? t.attributedPlaceholder?.string) { return p }
            }
            return madeBySwiftUI(f) ? nil : clean(appLabel(f))
        }

        /// Whether a view takes taps of its own: one off the path pressed is a nested control, whose text is its own. A
        /// view that takes no touch is part of the control around it, as a bar button's title button is.
        private static func takesTaps(_ v: UIView) -> Bool {
            v.isUserInteractionEnabled
                && (v is UIControl || v is UITableViewCell || v is UICollectionViewCell || listens(v))
        }

        /// The text a control shows: every label inside it, but none inside a control nested in it off the path
        /// pressed, a field, or a masked or ignored view; an image's label only where nothing else is shown.
        private static func textOf(_ control: UIView, _ chain: [UIView], imageLabels: Bool) -> String? {
            let onChain = Set(chain.map { ObjectIdentifier($0) })
            var parts: [String] = []
            var images: [String] = []
            var length = 0
            var budget = 400
            func visit(_ v: UIView) {
                budget -= 1
                if length > Limits.maxText || budget < 0 { return }
                if v.isHidden || v.alpha <= 0.01 || v.kontalaMask || v.kontalaIgnore || isField(v) { return }
                if v !== control && !onChain.contains(ObjectIdentifier(v)) && takesTaps(v) { return }
                if let l = v as? UILabel {
                    if let t = clean(l.text ?? l.attributedText?.string) {
                        parts.append(t)
                        length += t.count
                    }
                    return
                }
                if let tv = v as? UITextView {
                    if let t = clean(tv.text) {
                        parts.append(t)
                        length += t.count
                    }
                    return
                }
                if imageLabels, v is UIImageView, let a = clean(appLabel(v)) { images.append(a) }
                for s in v.subviews { visit(s) }
            }
            visit(control)
            // A button's title, where its label is not one of its views yet: a button never laid out.
            if parts.isEmpty, let b = control as? UIButton {
                var title = b.currentTitle
                if title == nil, #available(iOS 15, *) { title = b.configuration?.title }
                if let t = clean(title) { parts.append(t) }
            }
            let t = collapse((parts.isEmpty ? Array(images.prefix(1)) : parts).joined(separator: " "), Limits.maxText)
            return t.isEmpty ? nil : t
        }

        /// The http or https link of a text view's text under [point], in its window, and the text it is on.
        private static func linkAt(_ tv: UITextView, _ point: CGPoint) -> (url: String, text: String?)? {
            if tv.isEditable { return nil }
            let p = tv.convert(point, from: nil)
            guard let pos = tv.closestPosition(to: p) else { return nil }
            let offset = tv.offset(from: tv.beginningOfDocument, to: pos)
            let text = tv.attributedText ?? NSAttributedString()
            // The character the point is on, or the one before it at a line's end.
            for at in [offset, offset - 1] where at >= 0 && at < text.length {
                var range = NSRange()
                let value = text.attribute(.link, at: at, effectiveRange: &range)
                let url = (value as? URL)?.absoluteString ?? (value as? String)
                guard let u = url, let scheme = u.split(separator: ":").first?.lowercased() else { continue }
                if scheme == "http" || scheme == "https" {
                    let run = collapse(text.attributedSubstring(from: range).string, Limits.maxText)
                    return (cutBytes(u, Limits.maxURL), run.isEmpty ? nil : run)
                }
            }
            return nil
        }

        /// A class's name: an app class's own, generic arguments cut, and a system class's nearest public one, since
        /// a private class's name changes with iOS.
        static func displayName(_ cls: AnyClass) -> String {
            if !isSystem(cls) {
                let full = String(describing: cls)
                return full.split(separator: "<").first.map(String.init) ?? full
            }
            var c: AnyClass? = cls
            while let k = c {
                let n = NSStringFromClass(k)
                if !n.hasPrefix("_") && !n.contains(".") { return n }
                c = class_getSuperclass(k)
            }
            return "UIView"
        }

        /// The control's class, and the nearest of the app's own views above it: the `ProductCard` that tells one Add
        /// button from another.
        private static func classNameOf(_ chain: [UIView], _ index: Int) -> String? {
            let own = displayName(type(of: chain[index]))
            var app: String?
            var i = index - 1
            while i >= 0 && i >= index - 60 {
                let v = chain[i]
                if appView(v) {
                    app = displayName(type(of: v))
                    break
                }
                // The screen's own view is the last a control's class looks to.
                if v.next is UIViewController { break }
                i -= 1
            }
            let joined = [own, app].compactMap { $0 }.reduce(into: [String]()) { out, n in
                if !out.contains(n) { out.append(n) }
            }.joined(separator: " ")
            return joined.isEmpty ? nil : cutBytes(joined, Limits.maxAttribute)
        }

        /// UIKit's structures a control's path names, beside the app's own views and those with an identifier.
        private static func structural(_ v: UIView) -> Bool {
            if v is UITextView { return false }
            return v is UIScrollView || v is UINavigationBar || v is UITabBar || v is UIToolbar || v is UISearchBar
                || v is UITableViewCell || v is UICollectionViewCell
        }

        /// At most eight meaningful ancestors, outermost first, as `Name#identifier` joined by ` > `, the screen that
        /// shows it first where there is room: UIKit's structures, the app's own views and those with an identifier. A
        /// masked control's path is bare names.
        private static func pathOf(_ chain: [UIView], _ index: Int, _ masked: Bool, _ owner: String?) -> String? {
            var segments: [String] = []
            let ids = !masked && !madeBySwiftUI(chain[index])
            var i = index
            while i >= 0 && segments.count < 8 {
                let v = chain[i]
                if v is UIWindow { break }
                let id = ids ? clean(appIdentifier(v)) : nil
                if i == index || structural(v) || appView(v) || id != nil {
                    let name = displayName(type(of: v))
                    segments.append(id.map { "\(name)#\($0)" } ?? name)
                }
                i -= 1
            }
            if let o = owner, segments.count < 8 { segments.append(o) }
            if segments.isEmpty { return nil }
            return cutRunes(segments.reversed().joined(separator: " > "), Limits.maxPath)
        }

        /// The view controller a view is in, the nearest on its responder chain.
        static func viewController(of v: UIView) -> UIViewController? {
            var r: UIResponder? = v.next
            var n = 0
            while let x = r, n < 200 {
                if let vc = x as? UIViewController { return vc }
                r = x.next
                n += 1
            }
            return nil
        }

        /// What a press's path names outermost: the nearest of the app's view controllers it is in, a dialog's being
        /// the screen under it; for a bar's control, which a container's view holds, the screen the container shows;
        /// and nothing for a SwiftUI screen, whose hosting controller is no class of the app's.
        static func ownerName(of v: UIView) -> String? {
            var vc = viewController(of: v) ?? v.window?.rootViewController.flatMap { ScreenKinds.front($0).last }
            while let c = vc {
                if ScreenKinds.container(c) { return ScreenKinds.front(c).last.flatMap(ScreenNames.className) }
                if let n = ScreenNames.className(c) { return n }
                vc = c.parent ?? (ScreenKinds.dialog(c) ? c.presentingViewController : nil)
            }
            return nil
        }

        private static func regionOf(_ chain: [UIView], _ index: Int, _ control: UIView) -> String {
            for i in stride(from: index, through: 0, by: -1) {
                let v = chain[i]
                if v is UINavigationBar { return "header" }
                if v is UITabBar { return "nav" }
                if v is UIToolbar { return "footer" }
            }
            var vc = viewController(of: control)
            while let c = vc {
                if ScreenKinds.dialog(c) { return "dialog" }
                vc = c.parent
            }
            return "main"
        }

        // Forms, from contract 2.

        /// A text field as the form rules read it.
        static func fieldInfo(_ f: UIView, _ chain: [UIView]? = nil) -> FieldInfo {
            let c = chain ?? Self.chain(to: f)
            var info = FieldInfo(
                name: madeBySwiftUI(f) ? nil : clean(appIdentifier(f)), label: fieldLabel(f),
                search: searchField(f, c, c.count - 1))
            if let t = f as? UITextField {
                let type = t.textContentType?.rawValue
                if let h = type.flatMap(Hints.ofContentType) { info.hints = [h] }
                info.obscured = t.isSecureTextEntry
                info.email = t.keyboardType == .emailAddress || type == "email"
                info.value = t.text ?? ""
            } else if let tv = f as? UITextView {
                let type = tv.textContentType?.rawValue
                if let h = type.flatMap(Hints.ofContentType) { info.hints = [h] }
                info.obscured = tv.isSecureTextEntry
                info.multiline = true
                info.email = tv.keyboardType == .emailAddress || type == "email"
                info.value = tv.text ?? ""
            }
            return info
        }

        /// Whether a field submits on the keyboard's key: every one-line field whose key does not move on to the next.
        static func submits(_ f: UIView) -> Bool {
            guard let t = f as? UITextField else { return false }
            return t.returnKeyType != .next
        }

        /// The index of the field's own search bar above it, which the container of a form it belongs to must be
        /// above.
        static func fieldOuter(_ chain: [UIView], _ field: Int) -> Int {
            var outer = field
            var i = field - 1
            while i >= 0 && i >= field - 8 {
                if chain[i] is UISearchBar { outer = i }
                i -= 1
            }
            return outer
        }

        private static func maskedView(_ v: UIView) -> Bool { v.kontalaMask || v.kontalaIgnore }

        private static func holdsField(_ scope: UIView, _ skip: UIView?, _ budget: inout Int) -> Bool {
            var found = false
            func visit(_ v: UIView) {
                budget -= 1
                if found || budget < 0 || v === skip || maskedView(v) { return }
                if isField(v) {
                    found = true
                    return
                }
                for s in v.subviews { visit(s) }
            }
            visit(scope)
            return found
        }

        /// The form a control belongs to: the nearest of its five closest containers that holds a text field, the
        /// web's rule for a button outside a `<form>`, since UIKit has no form of its own.
        static func formScope(_ chain: [UIView], _ control: Int) -> UIView? {
            var budget = 1500
            var searched: UIView?
            var containers = 0
            var i = control - 1
            while i >= 0 && containers < 5 && budget > 0 {
                let g = chain[i]
                let edge = screenEdge(g)
                if edge == .before { return nil }
                if g.subviews.count >= 2 {
                    containers += 1
                    if holdsField(g, searched, &budget) { return g }
                    searched = g
                }
                if edge == .after { return nil }
                i -= 1
            }
            return nil
        }

        enum ScreenEdge { case none, before, after }

        /// Where a walk up from a control for its form stops, as the Android SDK's stops at its content view: after
        /// the screen's own view, the last a form can be; and before a container's view or a window, since a
        /// container's view holds a bar's controls beside the screen's view, and with it every field of the screen,
        /// which a back button would otherwise send.
        static func screenEdge(_ g: UIView) -> ScreenEdge {
            if g is UIWindow { return .before }
            guard let vc = g.next as? UIViewController else { return .none }
            return ScreenKinds.container(vc) ? .before : .after
        }

        /// The text fields inside [scope], in the order they are laid out, leaving out what is masked or ignored.
        static func fieldsIn(_ scope: UIView) -> [FieldInfo] {
            var out: [FieldInfo] = []
            var budget = 1500
            func visit(_ v: UIView) {
                budget -= 1
                if budget < 0 || out.count >= 64 || maskedView(v) { return }
                if isField(v) {
                    out.append(fieldInfo(v))
                    return
                }
                for s in ordered(v.subviews) { visit(s) }
            }
            visit(scope)
            return out
        }

        /// What [scope] holds, in order: each text field, and each choice's value under its name.
        static func entriesIn(_ scope: UIView) -> [Forms.Entry] {
            var out: [Forms.Entry] = []
            var budget = 3000
            func visit(_ v: UIView) {
                budget -= 1
                if budget < 0 || maskedView(v) { return }
                if isField(v) {
                    out.append(.text(fieldInfo(v)))
                } else if let s = v as? UISwitch {
                    out.append(.choice(name: choiceName(s), value: Forms.text(s.isOn)))
                } else if let s = v as? UISegmentedControl {
                    let i = s.selectedSegmentIndex
                    let title = i >= 0 ? s.titleForSegment(at: i) : nil
                    out.append(.choice(name: choiceName(s), value: title ?? (i >= 0 ? String(i) : nil)))
                } else if let s = v as? UISlider {
                    out.append(.choice(name: choiceName(s), value: Forms.text(Double(s.value))))
                } else if let s = v as? UIStepper {
                    out.append(.choice(name: choiceName(s), value: Forms.text(s.value)))
                } else {
                    for c in ordered(v.subviews) { visit(c) }
                }
            }
            visit(scope)
            return out
        }

        /// Views in the order a reader meets them: top to bottom, then leading to trailing, as a form is laid out.
        private static func ordered(_ views: [UIView]) -> [UIView] {
            views.enumerated().sorted { a, b in
                let fa = a.element.frame
                let fb = b.element.frame
                if abs(fa.minY - fb.minY) > 1 { return fa.minY < fb.minY }
                if abs(fa.minX - fb.minX) > 1 { return fa.minX < fb.minX }
                return a.offset < b.offset
            }.map { $0.element }
        }

        /// A choice's name: its own identifier, else that of one of the few views around it.
        private static func choiceName(_ v: UIView) -> String? {
            if madeBySwiftUI(v) { return nil }
            var x: UIView? = v
            var n = 0
            while let y = x, n < 6 {
                if let id = clean(appIdentifier(y)) { return id }
                x = y.superview
                n += 1
            }
            return nil
        }

        /// Whether the control is a field's own, a clear button or a search bar's, which submits nothing.
        static func fieldsOwnControl(_ chain: [UIView], _ control: Int, _ scope: UIView) -> Bool {
            var i = control - 1
            while i >= 0 {
                let v = chain[i]
                if v === scope { return false }
                if v is UISearchBar || isField(v) { return true }
                i -= 1
            }
            return false
        }

        /// The term of the one search box a tap on a button sends: the one search box in the nearest of the control's
        /// five closest containers holding exactly one. Nil where there is none, it holds nothing, or it is withheld.
        static func searchTerm(_ chain: [UIView], _ control: Int) -> String? {
            var containers = 0
            var i = control - 1
            while i >= 0 && containers < 5 {
                let g = chain[i]
                let edge = screenEdge(g)
                if edge == .before { break }
                if g.subviews.count >= 2 {
                    containers += 1
                    let boxes = fieldsIn(g).filter { $0.search }
                    if boxes.count == 1 { return Forms.term(boxes[0]) }
                    if boxes.count > 1 { return nil }
                }
                if edge == .after { break }
                i -= 1
            }
            return nil
        }
    }
#endif
