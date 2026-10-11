/// The library's own name, as the Events API's `context.library` reads it.
package let sdkLibraryName = "kontala-ios"

/// The SDK's version, which every request names.
package let sdkVersion = "0.1.0"

/// What the core reads about the app and the device once, from the platform, and keeps for the process: the Flutter
/// plugin's `facts`.
package struct PlatformFacts: Equatable {
    /// The bundle id, which the API reads as the hostname.
    package var appId: String
    package var appVersion: String?
    package var appBuild: String?
    /// ios, ipados or android.
    package var osName: String
    package var osVersion: String?
    package var manufacturer: String?
    /// The machine identifier, such as `iPhone16,1`, or Android's `Build.MODEL`.
    package var model: String?
    /// The IANA zone.
    package var timezone: String?
    /// The directory the SDK keeps its files in, which a backup never copies, so a backup restored to a new phone
    /// never makes two devices one.
    package var storageDir: String?
    /// The app that opened a deep link.
    package var referrer: String?
    package var isTablet: Bool
    /// The major version of Android's WebView package; none on iOS.
    package var webViewMajor: Int?
    /// A simulator or an emulator, whose events are a developer's.
    package var isVirtual: Bool
    /// When the app's process started, in microseconds since the epoch, which a cold start's first screen is timed
    /// from.
    package var processStartMicros: Int64?
    /// debug or release: how the app was built, which the API reads as a developer's when it is not a release.
    package var buildMode: String

    package init(
        appId: String, appVersion: String? = nil, appBuild: String? = nil, osName: String,
        osVersion: String? = nil, manufacturer: String? = nil, model: String? = nil, timezone: String? = nil,
        storageDir: String? = nil, referrer: String? = nil, isTablet: Bool = false, webViewMajor: Int? = nil,
        isVirtual: Bool = false, processStartMicros: Int64? = nil, buildMode: String = "release"
    ) {
        self.appId = appId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osName = osName
        self.osVersion = osVersion
        self.manufacturer = manufacturer
        self.model = model
        self.timezone = timezone
        self.storageDir = storageDir
        self.referrer = referrer
        self.isTablet = isTablet
        self.webViewMajor = webViewMajor
        self.isVirtual = isVirtual
        self.processStartMicros = processStartMicros
        self.buildMode = buildMode
    }

    package var isIOS: Bool { osName == "ios" || osName == "ipados" }

    /// Facts as the Flutter plugin's map names them, which the shared vectors are written in.
    package static func fromMap(_ m: JSONObject) -> PlatformFacts {
        func s(_ k: String) -> String? {
            guard let v = m.str(k), !v.isEmpty else { return nil }
            return v
        }
        let started = m[("processStartMs")]?.number.map { Int64($0) }
        return PlatformFacts(
            appId: s("appId") ?? "unknown.app",
            appVersion: s("appVersion"),
            appBuild: s("appBuild"),
            osName: s("osName") ?? "android",
            osVersion: s("osVersion"),
            manufacturer: s("manufacturer"),
            model: s("model"),
            timezone: s("timezone"),
            storageDir: s("storageDir"),
            referrer: s("referrer"),
            isTablet: m["isTablet"] == .bool(true),
            webViewMajor: m["webViewMajor"]?.number.map { Int($0) },
            isVirtual: m["isVirtual"] == .bool(true),
            processStartMicros: started.flatMap { $0 > 0 ? $0 * 1000 : nil }
        )
    }
}

/// What a context snapshot reads of the platform at the moment an event is captured.
package protocol Environment: AnyObject {
    /// The visitor's language tag, such as `nl-NL`.
    func localeTag() -> String?

    /// The app's window in points, or nil where it has none.
    func displaySize() -> (Int, Int)?
}

/// Takes each event's context snapshot: the app, its screen, the locale, the time zone, the window's size, the
/// library and the user agent, every value held to the API's own patterns first, since one value it refuses refuses
/// every event of the batch that shares it.
package final class ContextBuilder {
    private let options: KontalaContextOptions
    private let libraryVersion: String
    private weak var environment: Environment?

    package private(set) var facts: PlatformFacts?
    private var appIdOk: String?
    private var userAgent: String?

    /// Turned off for the process once the API refused a value of the kind, so the events after it are not refused
    /// for it too.
    package var localeRefused = false
    package var timezoneRefused = false

    package init(options: KontalaContextOptions, libraryVersion: String, environment: Environment) {
        self.options = options
        self.libraryVersion = libraryVersion
        self.environment = environment
    }

    /// Takes what the platform read, which the snapshots taken before it came are `complete`d with.
    package func setFacts(_ facts: PlatformFacts) {
        self.facts = facts
        let id = facts.appId.lowercased().replacingOccurrences(of: "_", with: "-")
        appIdOk = id.utf16.count <= 253 && Limits.appHost.matches(id) ? facts.appId : nil
        userAgent = buildUserAgent(facts, sdkVersion, model: options.deviceModel, osVersion: options.osVersion)
    }

    /// The app id the API files events under, or nil where the platform's is not one it takes.
    package var appId: String? { appIdOk }

    /// The context of an event captured now, on [screen].
    package func snapshot(_ screen: String?) -> ContextSnapshot {
        let f = facts
        let size = options.display ? displaySize() : nil
        return ContextSnapshot(
            appId: appIdOk ?? "",
            appVersion: ContextBuilder.version(f?.appVersion),
            appBuild: ContextBuilder.version(f?.appBuild),
            screen: screen,
            locale: options.locale && !localeRefused ? locale() : nil,
            timezone: options.timezone && !timezoneRefused ? ContextBuilder.zone(f?.timezone) : nil,
            displayWidth: size?.0,
            displayHeight: size?.1,
            libraryName: sdkLibraryName,
            libraryVersion: libraryVersion,
            userAgent: userAgent,
            appMode: f?.buildMode,
            osName: ContextBuilder.os(f?.osName),
            osVersion: options.osVersion ? ContextBuilder.version(f?.osVersion) : nil,
            manufacturer: options.deviceModel ? ContextBuilder.deviceText(f?.manufacturer) : nil,
            model: options.deviceModel ? ContextBuilder.deviceText(f?.model) : nil,
            virtual: f?.isVirtual ?? false
        )
    }

    /// [partial], taken before the platform answered, with what it said.
    package func complete(_ partial: ContextSnapshot) -> ContextSnapshot {
        guard let f = facts else { return partial }
        var c = partial
        c.appId = appIdOk ?? ""
        c.appVersion = ContextBuilder.version(f.appVersion)
        c.appBuild = ContextBuilder.version(f.appBuild)
        c.timezone = options.timezone && !timezoneRefused ? ContextBuilder.zone(f.timezone) : nil
        c.userAgent = userAgent
        c.appMode = f.buildMode
        c.osName = ContextBuilder.os(f.osName)
        c.osVersion = options.osVersion ? ContextBuilder.version(f.osVersion) : nil
        c.manufacturer = options.deviceModel ? ContextBuilder.deviceText(f.manufacturer) : nil
        c.model = options.deviceModel ? ContextBuilder.deviceText(f.model) : nil
        c.virtual = f.isVirtual
        return c
    }

    private func locale() -> String? {
        guard let tag = environment?.localeTag(), Limits.locale.matches(tag) else { return nil }
        return tag
    }

    /// The window's size, held to what the API's integer fields take.
    private func displaySize() -> (Int, Int)? {
        guard let (w, h) = environment?.displaySize() else { return nil }
        if w < 1 || h < 1 || w > Limits.maxDisplay || h > Limits.maxDisplay { return nil }
        return (w, h)
    }

    /// An IANA zone's name, never an offset such as `GMT+05:30`, which the API refuses.
    private static let zonePattern = Pattern("^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,3}$")

    package static func version(_ v: String?) -> String? {
        guard let v = v, Limits.appVersion.matches(v) else { return nil }
        return v
    }

    package static func zone(_ z: String?) -> String? {
        guard let z = z, z.utf16.count <= 64, z != "Local", zonePattern.matches(z) else { return nil }
        return z
    }

    package static func os(_ name: String?) -> String? {
        guard let n = name, n == "ios" || n == "ipados" || n == "android" else { return nil }
        return n
    }

    /// A maker's or a model's name as the API takes one: printable, at most 64 code points.
    package static func deviceText(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let t = printableText(s, 64)
        return t.isEmpty ? nil : t
    }
}

/// The user agent an app's events carry: the platform's own web view's, which the warehouse's browser, operating
/// system and device rules already read, with a `Kontala/<version>` token after it, which no bot rule matches.
///
/// It is built rather than read from a live web view, which costs 50 to 150 ms to start.
package func buildUserAgent(_ f: PlatformFacts, _ sdkVersion: String, model: Bool = true, osVersion: Bool = true)
    -> String
{
    func clean(_ s: String) -> String {
        var b = String.UnicodeScalarView()
        for u in s.unicodeScalars { b.append(u == ";" || u == "(" || u == ")" ? " " : u) }
        return printableText(String(b), 64)
    }
    let ua: String
    if f.isIOS {
        let ipad = f.osName == "ipados" || f.isTablet
        let v = osVersion ? f.osVersion.map { clean($0).replacingOccurrences(of: ".", with: "_") } : nil
        let os = ipad ? "CPU OS" : "CPU iPhone OS"
        let version = (v ?? "").isEmpty ? "" : "\(v!) "
        ua =
            "Mozilla/5.0 (\(ipad ? "iPad" : "iPhone"); \(os) \(version)like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Kontala/\(sdkVersion)"
    } else {
        // Chrome's reduced user agent writes these two where it hides them.
        let v = osVersion ? f.osVersion.map(clean) ?? "10" : "10"
        let m = model ? f.model.map(clean) ?? "K" : "K"
        let chrome = f.webViewMajor.map { "Chrome/\($0).0.0.0 " } ?? ""
        let mobile = f.isTablet ? "" : "Mobile "
        ua =
            "Mozilla/5.0 (Linux; Android \(v.isEmpty ? "10" : v); \(m.isEmpty ? "K" : m); wv) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 \(chrome)\(mobile)Safari/537.36 "
            + "Kontala/\(sdkVersion)"
    }
    return cutBytes(ua, Limits.maxUserAgent)
}
