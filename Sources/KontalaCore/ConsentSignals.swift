import Foundation

// What the visitor answered in a consent manager, as collector/consent names it: three buckets beside essential, which
// is always granted and never sent, and where each answer came from. The SDK reads and records them; nothing it
// stores, holds or sends depends on them. The Flutter SDK's core/consent_signals.dart, ported;
// collector/consent/testdata's vectors and sdk/testdata's consent_recorder hold the three to one set of answers.

/// What every event records of the visitor's answers in a consent manager: each bucket's answer, nil where nothing
/// spoke to it, where the answers came from, and how far the sources had got. A bucket nothing speaks to counts as
/// granted, and is sent as no signal, so an assumed grant is never mistaken for a given one.
public struct KontalaConsentSignals: Equatable {
    /// Functional: remembering choices and personalising for the visitor.
    public let functional: Bool?
    /// Performance and analytics.
    public let analytics: Bool?
    /// Targeting and advertising.
    public let targeting: Bool?
    /// The source that decided a bucket, else the one that answered, else, while `status` is `pending`, the one
    /// found: `app` or `tcf` in an app.
    public let source: String?
    /// `none` when no source was found, `pending` when a consent manager was found that has not answered yet, `ready`
    /// once one has.
    public let status: String
    /// Whether the visitor has answered the source, now or on an earlier launch, nil where the source cannot tell.
    public let decided: Bool?

    public init(
        functional: Bool? = nil, analytics: Bool? = nil, targeting: Bool? = nil, source: String? = nil,
        status: String, decided: Bool? = nil
    ) {
        self.functional = functional
        self.analytics = analytics
        self.targeting = targeting
        self.source = source
        self.status = status
        self.decided = decided
    }

    /// As the Events API reads `consent_signals`: an absent bucket is no signal.
    package func toJson() -> JSONObject {
        var o = JSONObject()
        if let v = functional { o["functional"] = .bool(v) }
        if let v = analytics { o["analytics"] = .bool(v) }
        if let v = targeting { o["targeting"] = .bool(v) }
        if let v = source { o["source"] = .string(v) }
        o["status"] = .string(status)
        if let v = decided { o["decided"] = .bool(v) }
        return o
    }

    /// Signals as `toJson` wrote them, or nil for what is not.
    package static func fromJson(_ raw: JSON?) -> KontalaConsentSignals? {
        guard let o = raw?.object, let status = o.str("status"), consentStatuses.contains(status) else { return nil }
        return KontalaConsentSignals(
            functional: o["functional"]?.bool, analytics: o["analytics"]?.bool, targeting: o["targeting"]?.bool,
            source: o.str("source").flatMap { consentSources.contains($0) ? $0 : nil }, status: status,
            decided: o["decided"]?.bool)
    }
}

/// The buckets a consent manager asks about beside essential, in the order every copy lists them.
package let consentBuckets = ["functional", "analytics", "targeting"]

/// Every source an answer can come from, in rank order: the order a bucket is decided in. What the app says comes
/// first, then what the page says, then the consent managers a page's tag reads natively, then the frameworks.
package let consentSources = [
    "app", "page", "onetrust", "cookiebot", "usercentrics", "didomi", "cookieyes", "trustarc", "shopify", "tcf", "gpp",
    "gcm",
]

/// The sources a served section may list and map: every source but `app` and `page`, whose answers are the buckets
/// themselves. An app reads `tcf` alone.
package let consentReaders = Array(consentSources.dropFirst(2))

/// How far a row's sources had got: none found, one found that has not answered yet, or one that has.
package let consentStatuses = ["none", "pending", "ready"]

/// The row sent when the signals change after a row of the screen carried others, which is what puts a consent manager
/// that answers after a screen view onto that view.
package let consentChangeName = "consent_change"

/// The most keys one source's answers carry on a change row, and the longest key.
package let maxConsentKeys = 32
package let maxConsentKeyLength = 64

/// Whether [key] is one a source may answer: a consent manager's own name for a category, nothing naming a visitor.
package func validConsentKey(_ key: String) -> Bool {
    let n = key.unicodeScalars.count
    guard n >= 1 && n <= maxConsentKeyLength else { return false }
    return key.unicodeScalars.allSatisfy { c in
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", ":", "-": return true
        default: return false
        }
    }
}

/// What one source answered: its own keys with a yes or a no, in the order it gave them, and whether the visitor
/// decided, nil where the source cannot tell.
package struct ConsentAnswer {
    package let source: String
    package let answers: [(key: String, value: Bool)]
    package let decided: Bool?

    package init(source: String, answers: [(key: String, value: Bool)], decided: Bool? = nil) {
        self.source = source
        self.answers = answers
        self.decided = decided
    }

    package func answer(_ key: String) -> Bool? { answers.first(where: { $0.key == key })?.value }
}

/// What a source's own keys mean for the buckets: each key, to the buckets it decides, in the order served.
package typealias ConsentMap = [(key: String, buckets: [String])]

/// How the app's own answers, which are the buckets themselves, map.
private let identityMap: ConsentMap = consentBuckets.map { ($0, [$0]) }

private func rank(_ source: String) -> Int { consentSources.firstIndex(of: source) ?? -1 }

/// What a row carries, given what each source answered and which sources were found without having answered yet, each
/// reader's answers read through its map in [catalog]: collector/consent's `Resolve`.
///
/// Per bucket, the first source in rank order whose mapped answers speak to it decides it: denied when any key mapped
/// to it was answered no, granted when one was answered and none no. The source named is the highest-ranked that
/// decided a bucket, else the highest-ranked that answered.
package func resolveConsent(
    _ answered: [ConsentAnswer], _ found: [String], _ catalog: [String: ConsentMap]
) -> KontalaConsentSignals {
    // Ordered by rank, and by the order given within one rank, as a stable sort keeps it.
    let ordered = answered.enumerated().sorted { a, b in
        let r = rank(a.element.source) - rank(b.element.source)
        return r != 0 ? r < 0 : a.offset < b.offset
    }.map(\.element)
    var buckets: [String: Bool] = [:]
    var decider = -1
    for bucket in consentBuckets {
        for (i, a) in ordered.enumerated() {
            let map = a.source == "app" || a.source == "page" ? identityMap : catalog[a.source]
            guard let v = decide(a, map, bucket) else { continue }
            buckets[bucket] = v
            if decider < 0 || i < decider { decider = i }
            break
        }
    }
    if !ordered.isEmpty {
        let named = ordered[decider < 0 ? 0 : decider]
        var decided = named.decided
        for a in ordered where decided == nil { decided = a.decided }
        return KontalaConsentSignals(
            functional: buckets["functional"], analytics: buckets["analytics"], targeting: buckets["targeting"],
            source: named.source, status: "ready", decided: decided)
    }
    if let first = found.min(by: { rank($0) < rank($1) }) {
        return KontalaConsentSignals(source: first, status: "pending")
    }
    return KontalaConsentSignals(status: "none")
}

/// One source's answer for one bucket: false when any key mapped to it was answered no, true when at least one was
/// answered and none no, and nil when none was answered.
private func decide(_ a: ConsentAnswer, _ map: ConsentMap?, _ bucket: String) -> Bool? {
    guard let map = map else { return nil }
    var spoke = false
    for (key, buckets) in map where buckets.contains(bucket) {
        guard let v = a.answer(key) else { continue }
        if !v { return false }
        spoke = true
    }
    return spoke ? true : nil
}

/// The served configuration's consent section, the one a page's tag is served: the readers to run, in rank order, and
/// what each one's answers mean. Of the readers an app runs `tcf` alone.
package struct ConsentSection: Equatable {
    package static func == (a: ConsentSection, b: ConsentSection) -> Bool { a.toJson() == b.toJson() }

    package let sources: [String]
    package let maps: [String: ConsentMap]
    /// The readers mapped, in the order served.
    package let mapped: [String]

    /// Whether the app reads the IAB TCF keys its consent manager writes.
    package var readsTcf: Bool { sources.contains("tcf") }

    /// The section as collector/consent's `Serve` writes it, or nil for one of another version or shape. Inside it, a
    /// source, a key or a bucket this SDK does not know is left out alone.
    package static func parse(_ raw: JSON?) -> ConsentSection? {
        guard let r = raw?.object, r["v"]?.number == 1, let sources = r.list("sources"), let maps = r.obj("maps")
        else { return nil }
        var s: [String] = []
        for x in sources {
            if let v = x.string, consentReaders.contains(v), !s.contains(v) { s.append(v) }
        }
        var m: [String: ConsentMap] = [:]
        var mapped: [String] = []
        for (source, keys) in maps {
            guard consentReaders.contains(source), let keys = keys.object else { continue }
            var map: ConsentMap = []
            for (key, buckets) in keys {
                if map.count == maxConsentKeys { break }
                guard validConsentKey(key), let list = buckets.array else { continue }
                let b = consentBuckets.filter { bucket in list.contains(.string(bucket)) }
                if !b.isEmpty { map.append((key, b)) }
            }
            m[source] = map
            mapped.append(source)
        }
        return ConsentSection(sources: s, maps: m, mapped: mapped)
    }

    /// As the SDK vectors write it: the readers, and each reader's map.
    package func toJson() -> JSONObject {
        var maps = JSONObject()
        for source in mapped {
            var keys = JSONObject()
            for (key, buckets) in self.maps[source] ?? [] { keys[key] = .array(buckets.map { .string($0) }) }
            maps[source] = .object(keys)
        }
        return ["sources": .array(sources.map { .string($0) }), "maps": .object(maps)]
    }
}

/// What an app's IAB TCF keys say: whether a consent manager wrote any, and its answer, nil while it has none.
package struct TcfReading {
    package let found: Bool
    package let answer: ConsentAnswer?
}

/// The keys handed over as stored, from the standard UserDefaults.
private let tcfStoredKeys = [
    "IABTCF_CmpSdkID", "IABTCF_gdprApplies", "IABTCF_PurposeConsents", "IABTCF_PublisherConsent",
]

/// The IAB TCF keys of the standard UserDefaults, read through [stored], each as stored where it is a number, a
/// string or a boolean, and `tc_string_present`, whether `IABTCF_TCString` is set: the string itself, which can
/// identify the visitor, is read for that alone and never kept.
package func tcfKeysOf(_ stored: (String) -> Any?) -> JSONObject {
    var out = JSONObject()
    for k in tcfStoredKeys {
        switch stored(k) {
        case let s as String: out[k] = .string(s)
        case let i as Int: out[k] = .int(Int64(i))
        case let i as Int64: out[k] = .int(i)
        case let d as Double: out[k] = .double(d)
        case let b as Bool: out[k] = .bool(b)
        default: break
        }
    }
    out["tc_string_present"] = .bool(!((stored("IABTCF_TCString") as? String) ?? "").isEmpty)
    return out
}

/// The IAB TCF v2.2 keys a consent manager writes in an app's standard UserDefaults, as `tcfKeysOf` hands them over.
///
/// GDPR not applying answers nothing. The publisher's own purpose consents are read where the consent manager records
/// them, else the purpose consents, a bit string whose character n is purpose n + 1: every purpose from 1 to 11 a yes
/// or a no. The visitor decided once there is a TC string.
package func readTcf(_ keys: JSONObject?) -> TcfReading {
    let k = keys ?? JSONObject()
    let purposes = k.str("IABTCF_PurposeConsents")
    let publisher = k.str("IABTCF_PublisherConsent")
    let tcString = k["tc_string_present"] == .bool(true)
    let present = { (key: String) -> Bool in k[key].map { !$0.isNull } ?? false }
    let found =
        present("IABTCF_CmpSdkID") || present("IABTCF_gdprApplies") || purposes != nil || publisher != nil || tcString
    if !found { return TcfReading(found: false, answer: nil) }
    if tcfNumber(k["IABTCF_gdprApplies"]) == 0 {
        return TcfReading(found: true, answer: ConsentAnswer(source: "tcf", answers: []))
    }
    guard let p = purposes else { return TcfReading(found: true, answer: nil) }
    let chosen = publisher.flatMap { $0.isEmpty ? nil : $0 } ?? p
    // Read as UTF-16 code units, as Dart and Kotlin index a string.
    let bits = Array(chosen.utf16)
    let one = UInt16(UInt8(ascii: "1"))
    let answers = (1...11).map { n in (key: "\(n)", value: n <= bits.count && bits[n - 1] == one) }
    return TcfReading(found: true, answer: ConsentAnswer(source: "tcf", answers: answers, decided: tcString))
}

/// A number as a consent manager stored it: IAB says an integer, and some store a string or a boolean instead.
private func tcfNumber(_ v: JSON?) -> Int? {
    switch v {
    case .int(let i)?: return Int(i)
    case .double(let d)?: return d.isFinite ? Int(d) : nil
    case .string(let s)?: return Int(s.trimmingCharacters(in: .whitespaces))
    case .bool(let b)?: return b ? 1 : 0
    default: return nil
    }
}

/// What the app and its consent manager said about the visitor, and the signals every event is stamped with: none
/// while the region serves no consent section, since without one nothing new is sent.
///
/// The app's answers are what `Kontala.consent` last said of analytics, granted or denied, overlaid by what
/// `Kontala.setConsentSignals` last said of each bucket, which replaces its own answers whole. They outrank the IAB
/// TCF keys the app's consent manager wrote, which the section maps.
package final class ConsentRecorder {
    private var section: ConsentSection?
    private var legacyAnswer: Bool?
    private var own: [(key: String, value: Bool)] = []
    private var tcfReading = TcfReading(found: false, answer: nil)

    /// What the next event is stamped with, or nil while nothing is.
    package private(set) var signals: KontalaConsentSignals?

    package init() {}

    /// Whether the served section has the app read its IAB TCF keys.
    package var readsTcf: Bool { section?.readsTcf ?? false }

    /// The section the region serves, or nil for none. Each of these answers whether the signals changed.
    package func served(_ section: ConsentSection?) -> Bool {
        self.section = section
        return update()
    }

    /// `Kontala.consent`: granted and denied are an answer for analytics; unknown is no answer, and leaves the last.
    package func legacy(_ state: KontalaConsent) -> Bool {
        switch state {
        case .granted: legacyAnswer = true
        case .denied: legacyAnswer = false
        case .unknown: return false
        }
        return update()
    }

    /// `Kontala.setConsentSignals`: the app's own answers, replaced whole; a nil says nothing of its bucket, and all
    /// nil leaves none.
    package func set(functional: Bool?, analytics: Bool?, targeting: Bool?) -> Bool {
        own = [("functional", functional), ("analytics", analytics), ("targeting", targeting)].compactMap { k, v in
            v.map { (key: k, value: $0) }
        }
        return update()
    }

    /// The IAB TCF keys, as the platform read them.
    package func tcf(_ keys: JSONObject?) -> Bool {
        tcfReading = readTcf(keys)
        return update()
    }

    /// The app's own answers: what `Kontala.consent` said of analytics, overlaid by what its signals said, each key in
    /// the place it was first given.
    private var app: [(key: String, value: Bool)] {
        var out: [(key: String, value: Bool)] = []
        if let l = legacyAnswer { out.append(("analytics", l)) }
        for (k, v) in own {
            if let i = out.firstIndex(where: { $0.key == k }) { out[i].value = v } else { out.append((k, v)) }
        }
        return out
    }

    private func answered() -> [ConsentAnswer] {
        var out: [ConsentAnswer] = []
        let a = app
        if !a.isEmpty { out.append(ConsentAnswer(source: "app", answers: a, decided: true)) }
        if readsTcf, let t = tcfReading.answer { out.append(t) }
        return out
    }

    /// Each answering source's own keys with a yes or a no, for a change row: only keys a source may answer, at most
    /// `maxConsentKeys` of each, the first in key order, and no source with none.
    package func answers() -> JSONObject {
        var out = JSONObject()
        for a in answered() {
            let valid = a.answers.filter { validConsentKey($0.key) }
            let kept = Set(valid.map(\.key).sorted().prefix(maxConsentKeys))
            var keys = JSONObject()
            for (k, v) in valid where kept.contains(k) { keys[k] = .bool(v) }
            if !keys.isEmpty { out[a.source] = .object(keys) }
        }
        return out
    }

    private func update() -> Bool {
        let next = section.map { s in resolveConsent(answered(), readsTcf && tcfReading.found ? ["tcf"] : [], s.maps) }
        let changed = next != signals
        signals = next
        return changed
    }
}
