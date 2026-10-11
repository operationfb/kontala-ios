import Foundation

/// What a navigation was, in the web's terms where it has them: the history shim's `pushstate`, `replacestate` and
/// `popstate` are `push`, `replace` and `pop`, and `tab`, `link` and `resume` are an app's own.
package enum NavigationKind: String {
    case launch
    case push
    case replace
    case pop
    case tab
    case link
    case resume

    package var wire: String { rawValue }
}

/// What the app declares about a screen: its name, page type and data.
package struct ScreenDeclaration {
    package var name: String?
    package var pageType: KontalaPageType?
    package var properties: JSONObject?

    package init(name: String? = nil, pageType: KontalaPageType? = nil, properties: JSONObject? = nil) {
        self.name = name
        self.pageType = pageType
        self.properties = properties
    }
}

/// What a screen is on the platform, held weakly, so the SDK never keeps a view controller the app has left alive,
/// and compared by what it holds.
package final class RouteRef {
    private weak var ref: AnyObject?

    package init(_ o: AnyObject) {
        ref = o
    }

    /// Whether this is [o]'s.
    package func isOf(_ o: AnyObject?) -> Bool {
        guard let o = o, let r = ref else { return false }
        return r === o
    }

    /// Whether this and [other] hold the same thing, which neither has let go of.
    package func same(_ other: RouteRef) -> Bool {
        guard let a = ref, let b = other.ref else { return false }
        return a === b
    }
}

/// A screen, as one page view describes it. Two are the same screen view only when they are one object.
package final class ScreenView {
    /// Path-shaped where the screen has a path (`/product/42`), so page type rules on paths read app screens.
    package let name: String
    /// The query string of the link that opened it, which carries a deep link's UTM tags to Channel.
    package let query: String?
    package let kind: NavigationKind
    package let declaration: ScreenDeclaration?
    /// What the screen is on the platform, a view controller, compared by identity: a later declaration of its own
    /// is filed on its view.
    package let route: RouteRef?
    /// The title the screen shows, read once it was drawn.
    package let title: String?
    /// Opened by a link the platform delivered.
    package let link: Bool

    package init(
        name: String, query: String? = nil, kind: NavigationKind, declaration: ScreenDeclaration? = nil,
        route: RouteRef? = nil, title: String? = nil, link: Bool = false
    ) {
        self.name = name
        self.query = query
        self.kind = kind
        self.declaration = declaration
        self.route = route
        self.title = title
        self.link = link
    }

    /// What the screen is deduplicated on, as the tag's page view is on `href`.
    package var url: String { query.map { "\(name)?\($0)" } ?? name }

    /// The screen opened again as a visit starts on it, without the query of the link that first opened it.
    package func resumed() -> ScreenView {
        ScreenView(name: name, query: nil, kind: .resume, declaration: declaration, route: route, title: title)
    }
}

/// A route name or a location split into a screen's name and query: a full URI is read as its path, a fragment is
/// dropped, and the name is held to what the API takes, as the Flutter SDK's `splitScreenName`.
package func splitScreenName(_ raw: String) -> (String, String?) {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var query: String?
    if s.contains("://") {
        if let u = URLComponents(string: s) {
            let path = u.percentEncodedPath
            s = path.isEmpty ? "/" : path
            query = u.percentEncodedQuery
        }
    } else {
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        if let q = s.firstIndex(of: "?") {
            query = String(s[s.index(after: q)...])
            s = String(s[..<q])
        }
    }
    if s.hasPrefix("/") {
        // A path that does not decode is kept as it was written.
        s = decodeComponent(s) ?? s
    }
    let name = printableText(s, Limits.maxScreenName)
    return (name.isEmpty ? "/" : name, cleanQuery(query))
}

/// The query of a link's address, or nil.
package func linkQuery(_ uri: String) -> String? {
    cleanQuery(URLComponents(string: uri)?.percentEncodedQuery)
}

/// [s] percent-decoded as Dart's `Uri.decodeComponent` decodes it, `+` kept, or nil where it does not decode.
package func decodeComponent(_ s: String) -> String? {
    let raw = Array(s.utf8)
    if !raw.contains(where: { $0 > 127 || $0 == UInt8(ascii: "%") }) { return s }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(raw.count)
    var i = 0
    while i < raw.count {
        let c = raw[i]
        if c > 127 { return nil }
        if c == UInt8(ascii: "%") {
            if i + 3 > raw.count { return nil }
            guard let hi = hexValue(raw[i + 1]), let lo = hexValue(raw[i + 2]) else { return nil }
            bytes.append(hi * 16 + lo)
            i += 2
        } else {
            bytes.append(c)
        }
        i += 1
    }
    return strictUTF8(bytes)
}

private func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

/// Fills a route template's parameters from its arguments, so a screen pushed with arguments is named as the app's
/// links name the same screen: `product/{id}` with `{id: 42}` is `product/42`, as go_router's `/product/:id` is
/// `/product/42` in the Flutter SDK. Both shapes are read, `{id}` and `:id`; a template whose arguments do not all fill
/// it is kept as it is, and a route's query template (`?tab={tab}`) is left out, being no part of the screen's path.
package func fillTemplate(_ name: String, _ arguments: [String: String]?) -> String {
    guard let arguments = arguments, name.contains(":") || name.contains("{") else { return name }
    let path = name.firstIndex(of: "?").map { String(name[..<$0]) } ?? name
    var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for i in parts.indices {
        let p = parts[i]
        let key: String
        if p.hasPrefix(":") {
            key = String(p.dropFirst())
        } else if p.hasPrefix("{") && p.hasSuffix("}") && p.count >= 2 {
            key = String(p.dropFirst().dropLast())
        } else {
            continue
        }
        guard let v = arguments[key], !v.isEmpty else { return name }
        parts[i] = encodeComponent(v)
    }
    return parts.joined(separator: "/")
}

private let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
private let upperHex: [Character] = Array("0123456789ABCDEF")

/// [s] percent-encoded as Dart's `Uri.encodeComponent` encodes it: everything but the unreserved characters and
/// `!*'()`.
package func encodeComponent(_ s: String) -> String {
    var b = ""
    for byte in s.utf8 {
        if unreserved.contains(byte) {
            b.unicodeScalars.append(Unicode.Scalar(byte))
        } else {
            b.append("%")
            b.append(upperHex[Int(byte >> 4)])
            b.append(upperHex[Int(byte & 0x0F)])
        }
    }
    return b
}
