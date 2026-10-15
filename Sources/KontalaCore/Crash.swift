import Foundation

/// What an uncaught exception's `js_error` row is stamped with, which the core publishes as it releases each granted
/// event, and again as what the visitor answered in a consent manager changes, for the thread that crashes: a process
/// an uncaught exception ends never runs the core again, so the row is written then and there, beside the queue, and
/// sent by the next launch (`queue/crash.jsonl`).
///
/// Only published while the property captures friction, consent is granted and the device may be written to, which
/// is every condition such a row is sent under.
package struct CrashContext {
    /// Where a crash's row waits for the next launch, which the queue reads as it restores.
    package static let file = EventQueue.crash

    /// The store's directory, which the queue's is in.
    package let dir: URL
    /// The view the app was on, which the row is filed under.
    package let view: String
    package let session: String?
    package let device: String?
    package let user: String?
    package let org: String?
    /// What the visitor had answered in a consent manager, which the row records as the event it was published from
    /// did, and as the next event released would; nil where the region serves no consent section.
    package let signals: KontalaConsentSignals?
    package let context: ContextSnapshot
    package let rules: FrictionRules
    /// The core's clock, read from the crashing thread, which it does not move.
    package let now: () -> Int64
    /// When the last event was captured, which the row is stamped after, so it sorts after the tap that caused it.
    package let after: Int64

    package init(
        dir: URL, view: String, session: String?, device: String?, user: String?, org: String?,
        signals: KontalaConsentSignals?, context: ContextSnapshot, rules: FrictionRules, now: @escaping () -> Int64,
        after: Int64
    ) {
        self.dir = dir
        self.view = view
        self.session = session
        self.device = device
        self.user = user
        self.org = org
        self.signals = signals
        self.context = context
        self.rules = rules
        self.now = now
        self.after = after
    }

    /// The same context, recording what the visitor answered since it was published.
    package func withSignals(_ signals: KontalaConsentSignals?) -> CrashContext {
        CrashContext(
            dir: dir, view: view, session: session, device: device, user: user, org: org, signals: signals,
            context: context, rules: rules, now: now, after: after)
    }
}

/// An error as the platform read it as it ended the process, before any of it is kept: its name, what it said, and
/// where in the app's own code it came from, where that is known.
package struct Thrown {
    package var name: String
    package var message: String
    package var source: String?
    package var line: Int64?

    package init(name: String, message: String, source: String? = nil, line: Int64? = nil) {
        self.name = name
        self.message = message
        self.source = source
        self.line = line
    }
}

/// The last tap before an error, as friction read it: how long before, and what it was on.
package struct TapBefore {
    package var ms: Int64
    package var fields: JSONObject

    package init(ms: Int64, fields: JSONObject) {
        self.ms = ms
        self.fields = fields
    }
}

/// Writes an uncaught error's `js_error` row, the Flutter SDK's `ErrorsPlugin` for a platform where one ends the
/// process, on the thread that crashed, by the rules the tag and the collector share: its name, where it is one a row
/// may carry, else read from its message; the first line of its message, normalised; its source where it is the
/// app's own code; and, within the served window of a tap, how long after it and what it was on. An error is written
/// once, and at most the served number a view and a launch.
package final class CrashRecorder {
    private let lock = NSLock()
    private var seen = Set<String>()
    private var perView: [String: Int] = [:]
    private var written = 0

    package init() {}

    /// Writes [thrown]'s row beside the queue, where it is one; answers whether it did.
    @discardableResult
    package func record(_ thrown: Thrown, _ c: CrashContext, tap: TapBefore?) -> Bool {
        let message = firstLine(thrown.message)
        if Messages.ignoredMessage(message) { return false }
        let name = Messages.validName(thrown.name) ? thrown.name : Messages.nameOf(message)
        let normalized = Messages.normalizeMessage(name, message)
        if name.isEmpty && normalized.isEmpty { return false }
        let source = thrown.source.flatMap { Messages.appSource($0) ? $0 : nil }
        let line = source == nil ? nil : thrown.line
        let key = ["error", name, normalized, source ?? "", line.map { String($0) } ?? ""].joined(separator: "\u{0}")
        let rules = c.rules
        lock.lock()
        let fits =
            !seen.contains(key) && (perView[c.view] ?? 0) < rules.errorsPerView && written < rules.errorsPerPage
        if fits {
            seen.insert(key)
            perView[c.view, default: 0] += 1
            written += 1
        }
        lock.unlock()
        if !fits { return false }
        let clicked = tap.map { $0.ms >= 0 && $0.ms <= Int64(rules.errorClickMs) } ?? false
        var error: JSONObject = ["kind": "error"]
        if !name.isEmpty { error["name"] = .string(name) }
        if !normalized.isEmpty { error["message"] = .string(normalized) }
        if let s = source {
            error["source"] = .string(s)
            if let l = line { error["line"] = .int(l) }
        }
        if clicked, let t = tap { error["since_click_ms"] = .int(t.ms) }
        var fields: JSONObject = ["error": .object(error)]
        if clicked, let t = tap { for (k, v) in t.fields { fields[k] = v } }
        let at = max(c.now(), c.after + 1)
        let event = CapturedEvent(
            id: Ids.uuidV7(floorDiv(at, 1000)),
            kind: "js_error",
            atMicros: at,
            fields: fields,
            context: c.context,
            view: c.view,
            consent: "granted",
            signals: c.signals,
            device: c.device,
            session: c.session,
            user: c.user,
            org: c.org
        )
        let file = c.dir.appendingPathComponent(CrashContext.file)
        let text = Json.encode(event.toStored()) + "\n"
        if FileStore.append(text, to: file.path) { return true }
        // The queue's directory is made as the context is published; a store emptied since makes it again.
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return FileStore.append(text, to: file.path)
    }

    /// Up to its first line feed, by code point, since a carriage return and a line feed are one `Character`.
    private func firstLine(_ message: String) -> String {
        let scalars = message.unicodeScalars
        guard let newline = scalars.firstIndex(of: "\n") else { return message }
        return String(scalars[..<newline])
    }
}
