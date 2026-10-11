/// Merges every navigation signal into one, the Flutter SDK's `NavigationHub` without Flutter's widgets: the screens
/// the platform's sources show (a view controller, a SwiftUI screen the app names), a screen the app names itself,
/// and the links the platform delivers.
///
/// A navigation is told at its first sign (`begin`) and its screen once it is on show (`shown`), as the Flutter SDK
/// tells a route's start synchronously and its screen after its first frame. A navigation while the app is not on
/// show opens no page view nobody saw: it is held until the app is shown. A launch that named no screen by its first
/// frame is filed as `/`.
package final class ScreenHub {
    /// A navigation began: the screen on show is being left.
    private let onStart: (NavigationKind) -> Void
    /// A screen is on show.
    private let onScreen: (ScreenView) -> Void
    /// A navigation began and settled with no screen to show.
    private let onIdle: () -> Void
    private let log: (String) -> Void

    private var started = false
    private var launched = false
    private var foreground = true
    private var held: ScreenView?
    private var link: String?
    private var kind: NavigationKind?
    private var warnedNoName = false

    /// The screen on show.
    package private(set) var current: ScreenView?

    package init(
        onStart: @escaping (NavigationKind) -> Void, onScreen: @escaping (ScreenView) -> Void,
        onIdle: @escaping () -> Void, log: @escaping (String) -> Void
    ) {
        self.onStart = onStart
        self.onScreen = onScreen
        self.onIdle = onIdle
        self.log = log
    }

    package func start(foreground: Bool) {
        started = true
        self.foreground = foreground
    }

    package func stop() {
        started = false
    }

    /// The app is shown again, or hidden: a navigation held while it was hidden goes on.
    package func setForeground(_ fg: Bool) {
        foreground = fg
        guard started, fg, let h = held else { return }
        held = nil
        publish(h)
    }

    /// A link the platform delivered: the navigation it causes is a `link`, and its query is the link's.
    package func linkPushed(_ uri: String) {
        if !started { return }
        link = uri
    }

    /// A navigation began: told once, at its first sign, before anything of its screen.
    package func begin(_ kind: NavigationKind) {
        if !started { return }
        if self.kind == nil {
            self.kind = kind
            onStart(kind)
        }
    }

    /// `Kontala.screen()`: the app names the screen itself, at once.
    package func manual(_ name: String, _ declaration: ScreenDeclaration?) {
        let (n, q) = splitScreenName(name)
        let kind: NavigationKind = launched ? .push : .launch
        launched = true
        self.kind = nil
        onStart(kind)
        publish(ScreenView(name: n, query: q, kind: kind, declaration: declaration))
    }

    /// A screen a platform source shows, named as the source names it, or [raw] nil where it names none: its kind is
    /// the launch's for the first, a link's where a link was just delivered, else the navigation's that began, else
    /// what the source says.
    package func shown(
        _ raw: String?, _ kind: NavigationKind, declaration: ScreenDeclaration? = nil, route: AnyObject? = nil,
        title: String? = nil
    ) {
        if !started { return }
        let begun = self.kind
        self.kind = nil
        let pendingLink = link
        guard let name = declaration?.name ?? raw ?? (!launched ? "/" : nil) else {
            if !warnedNoName {
                warnedNoName = true
                log("a screen had no name and was not sent: declare one with KontalaScreen or .kontalaScreen")
            }
            if begun != nil { onIdle() }
            return
        }
        link = nil
        let (n, named) = splitScreenName(name)
        var query = named
        if query == nil, let l = pendingLink { query = linkQuery(l) }
        let resolved: NavigationKind
        if !launched {
            resolved = .launch
        } else if pendingLink != nil {
            resolved = .link
        } else {
            resolved = begun ?? kind
        }
        // A screen no navigation began starts none, as a Router's change in the
        // Flutter SDK starts none.
        launched = true
        let view = ScreenView(
            name: n, query: query, kind: resolved, declaration: declaration, route: route.map { RouteRef($0) },
            title: title, link: pendingLink != nil)
        if !foreground {
            // Held until the app is shown, the latest screen alone.
            held = view
            return
        }
        publish(view)
    }

    /// After the launch's first frame: a launch nothing named is filed as `/`.
    package func launchCheck() {
        if !started || launched { return }
        launched = true
        kind = nil
        log(
            "no screen was named by the first frame, so the launch is filed as \"/\": name it with Kontala.screen, "
                + "or let a view controller name it")
        onStart(.launch)
        let pendingLink = link
        link = nil
        publish(ScreenView(name: "/", query: pendingLink.flatMap(linkQuery), kind: .launch, link: pendingLink != nil))
    }

    private func publish(_ view: ScreenView) {
        current = view
        onScreen(view)
    }
}
