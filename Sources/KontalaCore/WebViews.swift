import Foundation

/// collector/webview's rules, the SDK's side: what the app and a web page it shows in a web view must agree on to be
/// one visitor and one visit, which collector/webview/testdata/vectors.json holds this, the tag, the other SDKs and the
/// collector to. The Flutter SDK's `core/webviews.dart`, file for file.
package enum WebViews {
    /// The cookies the tag keeps its ids in, written with the attributes it writes them with
    /// (tag/core/core.identity.ts): a cookie of the same name with another Domain or Path would be a second cookie,
    /// and a page would read whichever came first.
    package static let deviceCookie = "pt_did"
    package static let sessionCookie = "pt_sid"

    /// The device cookie's lifetime, the tag's: two years.
    package static let deviceMaxAgeSeconds: Int64 = 63_072_000

    /// How much longer than the session's timeout the SDK's session cookie lives, since the SDK writes it at most
    /// every `writeIntervalMillis`: it never lapses before the session it holds.
    package static let sessionExtraSeconds: Int64 = 60

    /// The least time between two writes of the cookies that only slide them.
    package static let writeIntervalMillis: Int64 = 30_000

    /// The bridge protocol's version, on every message either side sends.
    package static let bridgeVersion = 1

    /// The global a page posts to the app through, with `postMessage(String)`, which `Kontala.attachWebView` gives a
    /// web view before its pages' own scripts run.
    package static let bridgeChannel = "KontalaAppBridge"
}

/// A visit's id and when it was last active, in epoch milliseconds, as the tag's `pt_sid` holds it: `<id>.<lastSeen in
/// base 36>`.
package struct WebSession: Equatable {
    package var id: String
    package var lastSeen: Int64

    package init(_ id: String, _ lastSeen: Int64) {
        self.id = id
        self.lastSeen = lastSeen
    }

    /// The `pt_sid` value, as the tag writes it.
    package var value: String { "\(id).\(String(lastSeen, radix: 36))" }

    private static let stamp = Pattern("^[0-9A-Za-z]{1,13}$")

    /// A `pt_sid` value read, or nil for one that holds no session. Any field after the second is ignored, so a later
    /// version may append one.
    package static func parse(_ raw: String?) -> WebSession? {
        guard let raw = raw, let dot = raw.firstIndex(of: "."), dot > raw.startIndex else { return nil }
        let id = String(raw[..<dot])
        let rest = raw[raw.index(after: dot)...]
        let stampText = String(rest.firstIndex(of: ".").map { rest[..<$0] } ?? rest)
        guard Ids.safeId.matches(id), stamp.matches(stampText),
            let seen = Int64(stampText.lowercased(), radix: 36)
        else { return nil }
        return WebSession(id, seen)
    }
}

/// The session the app and a page both keep once one has learned the other's (collector/webview.Merge):
/// - with one of the two, that one;
/// - with one id, that id, last seen at the later of the two;
/// - with two ids, the page's only when its last activity came at least [timeoutMillis] after the app's, so the app's
///   had lapsed and the page started a visit after it; otherwise the app's, last seen at the later of the two. Two
///   live visits are the page's not knowing the app's, and the app is the authority, which both sides applying the
///   same rule agrees on.
package func mergeSessions(_ app: WebSession?, _ page: WebSession?, _ timeoutMillis: Int64) -> WebSession? {
    guard let app = app else { return page }
    guard let page = page else { return app }
    let later = max(app.lastSeen, page.lastSeen)
    if app.id == page.id { return WebSession(app.id, later) }
    if page.lastSeen - app.lastSeen >= timeoutMillis { return page }
    return WebSession(app.id, later)
}

/// A website the app shows in a web view: its origin, and the cookie Domain its pages write their ids under, nil where
/// they write them host-only, as the tag does unless `data-cookie-domain` says otherwise.
package struct WebOrigin: Equatable, CustomStringConvertible {
    package let scheme: String
    package let host: String
    /// The port where it is not the scheme's own.
    package let port: Int?
    package let cookieDomain: String?

    /// `https://shop.example.com`, as a property lists it.
    package var value: String {
        "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port.map { ":\($0)" } ?? "")"
    }

    /// The page's own root, where the cookies are written for.
    package var url: String { "\(value)/" }

    /// Whether the tag marks its cookies Secure here: on an https page.
    package var secure: Bool { scheme == "https" }

    /// Whether [url], a page's address as its web view gives it, is a page on this origin.
    package func matches(_ url: String?) -> Bool {
        guard let u = PageUrl.of(url) else { return false }
        let p = u.port.flatMap { $0 == WebOrigin.defaultPort(u.scheme) ? nil : $0 }
        return u.scheme == scheme && u.host == host && p == port
    }

    package static func == (a: WebOrigin, b: WebOrigin) -> Bool {
        a.value == b.value && a.cookieDomain == b.cookieDomain
    }

    package var description: String { cookieDomain.map { "\(value) (\($0))" } ?? value }

    private static let origin = Pattern(
        "^https?://(\\[[0-9a-f:.]+]|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*)(:[0-9]{1,5})?$"
    )
    private static let domain = Pattern("^\\.?[a-z0-9][a-z0-9.-]{0,252}$")

    /// An origin as a property lists it, lower case, with no path: nil for one no property may list. A cookie Domain
    /// its pages could not set is left out, as the tag leaves it out.
    package static func parse(_ origin: String, cookieDomain: String? = nil) -> WebOrigin? {
        let o = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard self.origin.matches(o), let u = PageUrl.of(o) else { return nil }
        let port = u.port.flatMap { $0 == defaultPort(u.scheme) ? nil : $0 }
        let d = cookieDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return WebOrigin(
            scheme: u.scheme, host: u.host, port: port, cookieDomain: d.flatMap { domainFits($0, u.host) ? $0 : nil })
    }

    /// Whether a page on [host] may set a cookie for [domain], as the tag decides before it writes one.
    package static func domainFits(_ domain: String, _ host: String) -> Bool {
        guard self.domain.matches(domain), !host.isEmpty else { return false }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == bare || host.hasSuffix(".\(bare)")
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }
}

/// The parts of a page's address an origin is matched by, read as Dart's `Uri` reads them: the scheme and host in
/// lower case, an IPv6 host without its brackets, and the port where the address says one.
package struct PageUrl {
    package let scheme: String
    package let host: String
    package let port: Int?

    package static func of(_ url: String?) -> PageUrl? {
        guard let url = url, let sep = url.range(of: "://"), sep.lowerBound > url.startIndex else { return nil }
        let scheme = url[..<sep.lowerBound].lowercased()
        let rest = url[sep.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<end]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        let host: Substring
        let portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                portText = after.dropFirst()
            } else if after.isEmpty {
                portText = nil
            } else {
                return nil
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            portText = authority[authority.index(after: colon)...]
        } else {
            host = authority
            portText = nil
        }
        if host.isEmpty { return nil }
        var port: Int?
        if let t = portText, !t.isEmpty {
            guard t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t), n <= 65535 else { return nil }
            port = n
        }
        return PageUrl(scheme: scheme, host: host.lowercased(), port: port)
    }
}

/// A cookie write as `document.cookie` takes it, byte for byte the tag's `serialize`: the value encoded, Max-Age,
/// Path, the Domain where there is one, SameSite and, on an https page, Secure.
package func cookieHeader(_ name: String, _ value: String, _ maxAgeSeconds: Int64, _ origin: WebOrigin) -> String {
    var b = "\(name)=\(encodeComponent(value))"
    b += "; Max-Age=\(maxAgeSeconds)"
    b += "; Path=/"
    if let d = origin.cookieDomain { b += "; Domain=\(d)" }
    b += "; SameSite=Lax"
    if origin.secure { b += "; Secure" }
    return b
}

/// What a page posts to the app, read: only a message of this protocol, and after the hello only one carrying the
/// nonce the app gave the page, which a frame of another origin cannot read.
package enum PageMessage: Equatable {
    /// A page with the tag on it says hello, asking for the app's context.
    case hello
    /// The page's last activity, which slides the app's visit.
    case activity(WebSession)
    /// Who the page's own sign-in names, or no one.
    case identify(user: String?, org: String?)

    /// A page's message, or nil for one the app ignores.
    package static func read(_ raw: String, nonce: String) -> PageMessage? {
        guard let m = (try? Json.decode(raw))?.object else { return nil }
        // A number Dart reads as 1, 1.0 among them.
        guard m["kontala"]?.number == Double(WebViews.bridgeVersion) else { return nil }
        let type = m.str("type")
        if type == "hello" { return .hello }
        guard m["nonce"] == .string(nonce) else { return nil }
        switch type {
        case "activity":
            guard let id = m.str("session"), Ids.safeId.matches(id), let seen = m.long("last_seen"), seen > 0 else {
                return nil
            }
            return .activity(WebSession(id, seen))
        case "identify":
            func valid(_ v: JSON?) -> String? {
                guard let s = v?.string, Ids.safePrincipalId.matches(s) else { return nil }
                return s
            }
            return .identify(user: valid(m["user"]), org: valid(m["org"]))
        default:
            return nil
        }
    }
}

/// A cookie as the web views' store holds it, which the platform's store hands over for `WebCookies.pick`.
package struct StoredCookie: Equatable {
    package let name: String
    package let value: String
    /// `shop.example.com` for a host-only cookie, `.example.com` for one of a domain and its subdomains, as WebKit
    /// reports them.
    package let domain: String
    package let path: String
    package let secure: Bool

    package init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
    }
}

/// Which of the store's cookies a page sees, as WebKit sends them, the Flutter plugin's Swift.
package enum WebCookies {
    /// Whether a cookie for [domain] is sent to [host]: a host-only cookie, with no leading dot, to that host alone;
    /// a domain cookie, `.example.com`, to the domain and its every subdomain.
    package static func applies(_ domain: String, to host: String) -> Bool {
        guard domain.hasPrefix(".") else { return domain == host }
        return host == String(domain.dropFirst()) || host.hasSuffix(domain)
    }

    /// How specific a cookie's domain is: a host's own is read before a parent domain's.
    package static func specificity(_ domain: String) -> Int {
        domain.hasPrefix(".") ? domain.count - 1 : domain.count + 1
    }

    /// The values of the cookies [names] the pages of [origin] see: a host's own cookie, or a parent domain's, a
    /// Secure one only over https, at the root path, its own before a parent's, as `document.cookie` lists them.
    package static func pick(_ cookies: [StoredCookie], for origin: WebOrigin, _ names: [String]) -> [String: String] {
        var out: [String: String] = [:]
        let seen =
            cookies
            .filter {
                names.contains($0.name) && $0.path == "/" && applies($0.domain, to: origin.host)
                    && (origin.secure || !$0.secure)
            }
            .sorted { specificity($0.domain) > specificity($1.domain) }
        for c in seen where out[c.name] == nil { out[c.name] = c.value }
        return out
    }

    /// The domain a cookie for [origin] is written under: its pages' cookie Domain, read as `Domain=` reads it, for
    /// the domain and its subdomains, else the page's own host alone.
    package static func domain(for origin: WebOrigin) -> String {
        guard let d = origin.cookieDomain else { return origin.host }
        return d.hasPrefix(".") ? d : "." + d
    }
}
