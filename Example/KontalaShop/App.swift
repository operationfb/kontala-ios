import Kontala
import UIKit

/// What the build names, from Info.plist, which takes it from the build settings: `xcodebuild ... KONTALA_COLLECTOR=`
/// names another collector, as the Android shop's `-Pkontala.collector=` does.
enum Settings {
    private static func value(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    static var collector: String { value("KontalaCollector") }
    static var writeKey: String { value("KontalaWriteKey") }
    static var website: String { value("KontalaWebsite") }
    /// The Delivery and returns page's web view is attached unless the build says `none`.
    static var attachesWebView: Bool { value("KontalaWebView") != "none" }
    static var sessionMinutes: Int { Int(value("KontalaSessionMinutes")) ?? 30 }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // As the app starts, on the main thread: the launch's screen is read at its first frame. The website is
        // named for a development server's sake, which no property lists; an empty one names none.
        Kontala.start(
            writeKey: Settings.writeKey, endpoint: "\(Settings.collector)/v1/events",
            options: KontalaOptions(
                debug: true, sessionTimeout: TimeInterval(Settings.sessionMinutes * 60), flushInterval: 5,
                webOrigins: Settings.website.isEmpty ? [] : [Settings.website]))
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var navigation: UINavigationController? { window?.rootViewController as? UINavigationController }

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let s = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: s)
        let nav = UINavigationController(rootViewController: HomeViewController())
        nav.navigationBar.prefersLargeTitles = true
        w.rootViewController = nav
        w.makeKeyAndVisible()
        window = w
        // A cold start from a link: the SDK hears of it before the screen it opens is read.
        if let url = connectionOptions.urlContexts.first?.url { open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { open(url) }
    }

    /// `kontalashop://shop/product/42?utm_source=push` opens a product, its campaign's tags on the screen view.
    private func open(_ url: URL) {
        Kontala.handle(url: url)
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "product", let product = Shop.product(parts[1]) else { return }
        navigation?.pushViewController(ProductViewController(product: product), animated: false)
    }
}
