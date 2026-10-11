import Foundation

/// An event on its way out, as `KontalaOptions.beforeSend` sees it.
///
/// Its id, name, time and identity are fixed; what it says may be edited: a screen view's or a custom event's
/// `properties`, and a tap's `elementText` and `elementLabel`.
public struct KontalaEventData {
    public let id: String
    /// `page_view`, `click`, or a custom event's name.
    public let name: String
    /// When it was captured.
    public let timestamp: Date
    /// The screen the event happened on.
    public let screen: String?
    /// A screen view's or a custom event's data, nil on a tap.
    public var properties: [String: Any]?
    /// What the control tapped showed, and what it was called.
    public var elementText: String?
    public var elementLabel: String?

    package init(
        id: String, name: String, timestamp: Date, screen: String?, properties: [String: Any]?,
        elementText: String?, elementLabel: String?
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.screen = screen
        self.properties = properties
        self.elementText = elementText
        self.elementLabel = elementLabel
    }
}

/// Which facts about the device each event carries, Amplitude's `trackingOptions` for this SDK.
public struct KontalaContextOptions: Equatable {
    public var deviceModel: Bool
    public var osVersion: Bool
    public var locale: Bool
    public var timezone: Bool
    public var display: Bool
    /// The platform's own ids for the device - identifierForVendor and, where the visitor allowed tracking, the
    /// advertising id - and whether they did, read only on a consented event and sent beside the install id, never as
    /// it. Off, none is read.
    public var deviceIds: Bool

    public init(
        deviceModel: Bool = true, osVersion: Bool = true, locale: Bool = true, timezone: Bool = true,
        display: Bool = true, deviceIds: Bool = true
    ) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.locale = locale
        self.timezone = timezone
        self.display = display
        self.deviceIds = deviceIds
    }
}

/// How the SDK captures and sends, set once in `Kontala.start`. What a property captures (clicks, custom events,
/// scrolling, friction) is decided in Kontala; these are the app's own switches beside it.
public struct KontalaOptions {
    /// The consent state before the app says otherwise. `.granted` is the default, the web tag's permissive one: the
    /// app states the basis. An app that asks its visitors first starts at `.unknown` and answers with
    /// `Kontala.consent`.
    public var consent: KontalaConsent
    /// How long events wait for an answer while consent is unknown.
    public var consentHold: TimeInterval
    /// Logs every event captured and every refusal, as the tag's `data-debug`.
    public var debug: Bool
    /// Idle time after which the next event starts a new session.
    public var sessionTimeout: TimeInterval
    /// How long a batch waits for more events after its first.
    public var flushInterval: TimeInterval
    /// Events in one request, at most 200.
    public var maxBatchEvents: Int
    /// Keeps the ids in memory only and writes nothing to the device, the tag's cookieless mode.
    public var disableStorage: Bool
    /// A device id to use instead of the SDK's own, kept in memory only and never rotated.
    public var deviceId: String?
    /// A session id to use instead of the SDK's own, kept in memory only and never rotated.
    public var sessionId: String?
    /// Captures screen views.
    public var screens: Bool
    /// Captures taps.
    public var taps: Bool
    /// Captures `app_installed`, `app_updated`, `app_opened` and `app_backgrounded`.
    public var lifecycle: Bool
    /// Captures scroll depth and swipes, where the property captures scrolling.
    public var scroll: Bool
    /// Captures errors, rage and dead taps, returns and speed, where the property captures friction.
    public var friction: Bool
    /// Sends the text a tapped control shows. Off, a tap sends its role, id, label and class, but never what it shows.
    public var captureText: Bool
    /// Which facts about the device are sent.
    public var context: KontalaContextOptions
    /// Edits or drops each event before it is queued: answer nil to drop it. An error thrown here drops the event
    /// rather than sending it unchanged.
    public var beforeSend: ((KontalaEventData) throws -> KontalaEventData?)?
    /// Websites the app shows in a web view, as origins: `["https://shop.example.com", "http://localhost:4173"]`. The
    /// SDK shares its visitor and its visit with each, through the cookies the Kontala tag on its pages reads, and
    /// answers a page on one of them in a web view attached with `Kontala.attachWebView`.
    ///
    /// Kontala serves the property's own allowed origins, and the other websites the property names, on top of these,
    /// so they are needed only for a development host and for a region that does not serve them yet. An origin that
    /// is not one a property may list is left out.
    public var webOrigins: [String]

    public init(
        consent: KontalaConsent = .granted,
        consentHold: TimeInterval = 10,
        debug: Bool = false,
        sessionTimeout: TimeInterval = 30 * 60,
        flushInterval: TimeInterval = 15,
        maxBatchEvents: Int = 50,
        disableStorage: Bool = false,
        deviceId: String? = nil,
        sessionId: String? = nil,
        screens: Bool = true,
        taps: Bool = true,
        lifecycle: Bool = true,
        scroll: Bool = true,
        friction: Bool = true,
        captureText: Bool = true,
        context: KontalaContextOptions = KontalaContextOptions(),
        beforeSend: ((KontalaEventData) throws -> KontalaEventData?)? = nil,
        webOrigins: [String] = []
    ) {
        self.consent = consent
        self.consentHold = consentHold
        self.debug = debug
        self.sessionTimeout = sessionTimeout
        self.flushInterval = flushInterval
        self.maxBatchEvents = maxBatchEvents
        self.disableStorage = disableStorage
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.screens = screens
        self.taps = taps
        self.lifecycle = lifecycle
        self.scroll = scroll
        self.friction = friction
        self.captureText = captureText
        self.context = context
        self.beforeSend = beforeSend
        self.webOrigins = webOrigins
    }

    /// A duration in seconds as whole milliseconds, never below zero.
    package static func millis(_ t: TimeInterval) -> Int64 {
        guard t.isFinite, t > 0 else { return 0 }
        return Int64(min(t * 1000, Double(Int64.max / 1000)).rounded())
    }
}
