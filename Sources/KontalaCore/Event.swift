/// What an event happened in, taken when it was captured, so a rotation or a locale change halfway through a batch is
/// never filed under the wrong one. The wire encoder makes the commonest snapshot of a batch its `context` and states
/// on each event only what differs from it. Its stored form is the Flutter SDK's, key for key.
package struct ContextSnapshot: Equatable {
    package var appId: String
    package var appVersion: String?
    package var appBuild: String?
    /// The screen the event happened on, which files an event sent in a later request than its screen's page view
    /// under it.
    package var screen: String?
    package var locale: String?
    package var timezone: String?
    /// The window in points, always whole numbers.
    package var displayWidth: Int?
    package var displayHeight: Int?
    package var libraryName: String
    package var libraryVersion: String
    package var userAgent: String?
    // Contract 2's: how the app was built, its operating system and its
    // device. The wire encoder writes none of them to a collector on contract 1.
    /// debug, profile or release.
    package var appMode: String?
    /// ios, ipados or android.
    package var osName: String?
    package var osVersion: String?
    package var manufacturer: String?
    package var model: String?
    /// A simulator or an emulator.
    package var virtual: Bool
    /// The platform's ids for the device, set as a granted event is released and on no other.
    package var ids: DeviceIds?

    package init(
        appId: String, appVersion: String? = nil, appBuild: String? = nil, screen: String? = nil,
        locale: String? = nil, timezone: String? = nil, displayWidth: Int? = nil, displayHeight: Int? = nil,
        libraryName: String, libraryVersion: String, userAgent: String? = nil, appMode: String? = nil,
        osName: String? = nil, osVersion: String? = nil, manufacturer: String? = nil, model: String? = nil,
        virtual: Bool = false, ids: DeviceIds? = nil
    ) {
        self.appId = appId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.screen = screen
        self.locale = locale
        self.timezone = timezone
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.libraryName = libraryName
        self.libraryVersion = libraryVersion
        self.userAgent = userAgent
        self.appMode = appMode
        self.osName = osName
        self.osVersion = osVersion
        self.manufacturer = manufacturer
        self.model = model
        self.virtual = virtual
        self.ids = ids
    }

    package func withScreen(_ screen: String?) -> ContextSnapshot {
        var c = self
        c.screen = screen
        return c
    }

    /// The app's part of the context as the API reads it; its mode from contract 2.
    package func appJson(withScreen: Bool = true, contract: Int = 1) -> JSONObject {
        var o = JSONObject()
        o["id"] = .string(appId)
        if let v = appVersion { o["version"] = .string(v) }
        if let v = appBuild { o["build"] = .string(v) }
        if withScreen, let v = screen { o["screen"] = .string(v) }
        if contract >= 2, let v = appMode { o["mode"] = .string(v) }
        return o
    }

    package func displayJson() -> JSONObject? {
        guard let w = displayWidth, let h = displayHeight else { return nil }
        return ["width": .int(Int64(w)), "height": .int(Int64(h))]
    }

    package func libraryJson() -> JSONObject {
        ["name": .string(libraryName), "version": .string(libraryVersion)]
    }

    /// The operating system as contract 2 reads it, or nil for none.
    package func osJson() -> JSONObject? {
        guard let name = osName else { return nil }
        var o: JSONObject = ["name": .string(name)]
        if let v = osVersion { o["version"] = .string(v) }
        return o
    }

    /// The device as contract 2 reads it: its maker and model, whether it is a simulator, and on a granted event its
    /// ids and whether ad tracking is allowed. Never nil, so an event with no ids can state a device without them over
    /// a batch's that has some.
    package func deviceJson() -> JSONObject {
        var o = JSONObject()
        if let v = manufacturer { o["manufacturer"] = .string(v) }
        if let v = model { o["model"] = .string(v) }
        if virtual { o["virtual"] = .bool(true) }
        if let ids = ids?.idsJson(), !ids.isEmpty { o["ids"] = .object(ids) }
        if let t = ids?.adTracking { o["ad_tracking"] = .string(t) }
        return o
    }

    package func toJson() -> JSONObject {
        var o = JSONObject()
        o["appId"] = .string(appId)
        if let v = appVersion { o["appVersion"] = .string(v) }
        if let v = appBuild { o["appBuild"] = .string(v) }
        if let v = screen { o["screen"] = .string(v) }
        if let v = locale { o["locale"] = .string(v) }
        if let v = timezone { o["timezone"] = .string(v) }
        if let v = displayWidth { o["w"] = .int(Int64(v)) }
        if let v = displayHeight { o["h"] = .int(Int64(v)) }
        o["lib"] = .string(libraryName)
        o["libv"] = .string(libraryVersion)
        if let v = userAgent { o["ua"] = .string(v) }
        if let v = appMode { o["mode"] = .string(v) }
        if let v = osName { o["os"] = .string(v) }
        if let v = osVersion { o["osv"] = .string(v) }
        if let v = manufacturer { o["mfr"] = .string(v) }
        if let v = model { o["model"] = .string(v) }
        if virtual { o["virtual"] = .bool(true) }
        if let ids = ids { o["ids"] = .object(ids.toJson()) }
        return o
    }

    package static func fromJson(_ m: JSONObject) -> ContextSnapshot {
        ContextSnapshot(
            appId: m.str("appId") ?? "unknown.app",
            appVersion: m.str("appVersion"),
            appBuild: m.str("appBuild"),
            screen: m.str("screen"),
            locale: m.str("locale"),
            timezone: m.str("timezone"),
            displayWidth: m.long("w").map { Int($0) },
            displayHeight: m.long("h").map { Int($0) },
            libraryName: m.str("lib") ?? sdkLibraryName,
            libraryVersion: m.str("libv") ?? "0",
            userAgent: m.str("ua"),
            appMode: m.str("mode"),
            osName: m.str("os"),
            osVersion: m.str("osv"),
            manufacturer: m.str("mfr"),
            model: m.str("model"),
            virtual: m["virtual"] == .bool(true),
            ids: m.obj("ids").map { DeviceIds.fromMap($0) }
        )
    }
}

/// Where the visitor was when an event happened, which decides what the event does to their visit. Only time in the
/// foreground is activity: the moment the app is hidden is the last of it, and nothing the app does while hidden
/// starts a visit or keeps one going.
package enum Presence {
    /// In the app: the event slides the session, and starts a new one once the last has lapsed.
    case here
    /// Leaving it, as `app_backgrounded` says: the last moment the visitor was there, so it slides a session still
    /// live, but never starts one.
    case leaving
    /// Away, while the app is hidden: the event is filed under the session in force, which it neither slides nor
    /// starts.
    case away
}

/// One captured event, as the core stamps it.
///
/// `fields` are what the event is about, already in the API's own names (`screen`, `element`, `properties` and the
/// rest); the core adds the id, the time, the identity and the consent around them.
package final class CapturedEvent {
    package let id: String
    /// `page_view`, `click`, or a custom event's name.
    package let kind: String
    /// When it was captured, in microseconds since the epoch.
    package let atMicros: Int64
    /// The monotonic clock at capture, which lets a skewed clock be corrected at send time. Not kept across a restart.
    package let monotonic: Int64?
    package var fields: JSONObject
    package var context: ContextSnapshot
    /// The id of the page view the event happened on.
    package var view: String?
    /// Who the event names itself: a login's typed username, stamped in the halves the app's own identify leaves
    /// empty.
    package let namedUser: String?
    package let namedOrg: String?
    /// Where the visitor was, which the identity is resolved by. Needed only until the event is stamped, so never
    /// stored.
    package let presence: Presence
    package var consent: String
    /// What the visitor had answered in a consent manager, stamped with `consent` as the event is released; nil where
    /// the region serves no consent section.
    package var signals: KontalaConsentSignals?
    package var device: String?
    package var session: String?
    package var user: String?
    package var org: String?

    /// Whether the queue has sealed the event into a request, after which nothing about it can change.
    package var sealed = false

    /// A page view held back from sealing until this time, beyond the queue's settle.
    package var settleUntilMicros: Int64?

    package init(
        id: String, kind: String, atMicros: Int64, monotonic: Int64? = nil, fields: JSONObject,
        context: ContextSnapshot, view: String? = nil, namedUser: String? = nil, namedOrg: String? = nil,
        presence: Presence = .here, consent: String = "unknown", signals: KontalaConsentSignals? = nil,
        device: String? = nil, session: String? = nil, user: String? = nil, org: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.atMicros = atMicros
        self.monotonic = monotonic
        self.fields = fields
        self.context = context
        self.view = view
        self.namedUser = namedUser
        self.namedOrg = namedOrg
        self.presence = presence
        self.consent = consent
        self.signals = signals
        self.device = device
        self.session = session
        self.user = user
        self.org = org
    }

    package var isPageView: Bool { kind == "page_view" }

    /// The event as the queue keeps it on disk.
    package func toStored() -> JSONObject {
        var o = JSONObject()
        o["id"] = .string(id)
        o["kind"] = .string(kind)
        o["at"] = .int(atMicros)
        o["fields"] = .object(fields)
        o["ctx"] = .object(context.toJson())
        if let v = view { o["view"] = .string(v) }
        o["consent"] = .string(consent)
        if let v = signals { o["signals"] = .object(v.toJson()) }
        if let v = device { o["device"] = .string(v) }
        if let v = session { o["session"] = .string(v) }
        if let v = user { o["user"] = .string(v) }
        if let v = org { o["org"] = .string(v) }
        return o
    }

    /// The encoded size of the event, which the batch's byte budget counts.
    package var encodedLength: Int { utf8Length(Json.encode(toStored())) }

    package struct NotAnEvent: Error {}

    package static func fromStored(_ m: JSONObject) throws -> CapturedEvent {
        guard let id = m.str("id"), let kind = m.str("kind"), let at = m.long("at") else { throw NotAnEvent() }
        return CapturedEvent(
            id: id,
            kind: kind,
            atMicros: at,
            fields: m.obj("fields") ?? JSONObject(),
            context: ContextSnapshot.fromJson(m.obj("ctx") ?? JSONObject()),
            view: m.str("view"),
            consent: m.str("consent") ?? "unknown",
            signals: KontalaConsentSignals.fromJson(m["signals"]),
            device: m.str("device"),
            session: m.str("session"),
            user: m.str("user"),
            org: m.str("org")
        )
    }
}
