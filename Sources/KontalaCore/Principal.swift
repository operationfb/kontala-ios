/// Who the app says is using it: its own `user` and `org`, stamped on every later event, as tag/core/core.user.ts keeps
/// them.
///
/// `set` replaces both halves, so `identify()` with neither is the logout and no event is ever filed with a new user
/// and an old organisation. Each half is held to `Ids.safePrincipalId`; a bad value is dropped with one warning, never
/// thrown, since an app calls this from its own boot path. It lives in memory only and is never stored, so a logout
/// in one place never leaves another still claiming the old user.
package final class Principal {
    private let warn: ((String) -> Void)?
    private var warned = Set<String>()

    package private(set) var user: String?
    package private(set) var org: String?

    /// Who the sign-in of a web page the app shows names, told through the bridge: each half stamped only where the
    /// app's own and the event's name none, as a page stamps the app's.
    package private(set) var webUser: String?
    package private(set) var webOrg: String?

    package init(warn: ((String) -> Void)? = nil) {
        self.warn = warn
    }

    package func set(user: String? = nil, org: String? = nil) {
        self.user = valid(user, "user")
        self.org = valid(org, "org")
    }

    /// Replaces the web page's pair, whole as `set` replaces the app's. The bridge has held each half to the pattern.
    package func setWeb(user: String? = nil, org: String? = nil) {
        webUser = user
        webOrg = org
    }

    private func valid(_ value: String?, _ half: String) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        if Ids.safePrincipalId.matches(value) { return value }
        if warned.insert("\(half):\(value)").inserted {
            warn?("identify: \(half) is not a valid id and was dropped; an id is 1 to 254 of letters, digits and _.@+-")
        }
        return nil
    }
}

/// A principal an event names itself, a login's typed username for one, read only into the halves the app's own
/// `Principal` leaves empty, and only when valid; and where neither names one, who a web page the app shows names.
package func namedPrincipal(_ principal: Principal, user: String? = nil, org: String? = nil) -> (String?, String?) {
    func pick(_ own: String?, _ named: String?, _ web: String?) -> String? {
        if let o = own { return o }
        if let n = named, Ids.safePrincipalId.matches(n) { return n }
        return web
    }
    return (pick(principal.user, user, principal.webUser), pick(principal.org, org, principal.webOrg))
}
