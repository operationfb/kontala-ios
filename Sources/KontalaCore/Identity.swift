import Foundation

/// The ids `Identity.resolve` answers for one event.
package struct Resolved: Equatable {
    package let device: String
    package let session: String
    package let rotated: Bool
}

/// The device and session ids every event carries, with the rules of tag/core/core.identity.ts:
///
/// - the device is a random id for the install, never derived from anything about the device, and never one of the
///   platform's ids, which ride beside it;
/// - the session is `{id, last_seen}` behind a sliding idle window, rotated when `now - last_seen` reaches the timeout,
///   and kept when the clock moved back;
/// - time in the background is idle: an event while the app is hidden neither slides the session nor starts one, and
///   the moment it is hidden slides only a session still live (see `Presence`);
/// - nothing is written while storage is not allowed (consent other than granted, or `disableStorage`), and a change
///   away from it deletes the file and the ids;
/// - a pinned id lives in memory only and never rotates.
///
/// A device or a session just minted is written at once, since a process that ends before the next write would lose it,
/// and its next launch would be another visitor; `last_seen` alone is written at most once a second, and again on
/// `flush`.
package final class Identity {
    package static let file = "identity.json"

    private let store: FileStore
    package let timeoutMillis: Int64
    private let pinnedDevice: String?
    private let pinnedSession: String?

    private var storageAllowedFlag = false
    private var device: String?
    private var session: String?
    private var lastSeen: Int64?
    private var writtenAt: Int64?
    private var dirty = false

    package init(
        store: FileStore, timeoutMillis: Int64 = 30 * 60 * 1000, pinnedDevice: String? = nil,
        pinnedSession: String? = nil
    ) {
        self.store = store
        self.timeoutMillis = timeoutMillis
        self.pinnedDevice = pinnedDevice.flatMap { Ids.safeId.matches($0) ? $0 : nil }
        self.pinnedSession = pinnedSession.flatMap { Ids.safeId.matches($0) ? $0 : nil }
    }

    /// Whether the ids are kept on disk.
    package var storageAllowed: Bool { storageAllowedFlag && store.available }

    /// Allows or forbids storage. Allowing it reads the stored ids, so a returning visitor's device is legible once
    /// consent exists; forbidding it deletes them.
    package func setStorageAllowed(_ allowed: Bool) {
        if allowed == storageAllowedFlag { return }
        storageAllowedFlag = allowed
        if allowed {
            load()
            dirty = true
            flush()
        } else {
            store.delete(Identity.file)
            device = nil
            session = nil
            lastSeen = nil
        }
    }

    private func load() {
        guard let m = store.readJson(Identity.file) else { return }
        if let d = m.str("device"), Ids.safeId.matches(d) { device = d }
        // A pinned session is the app's own, and a stored one another's.
        guard pinnedSession == nil, let s = m.obj("session") else { return }
        if let id = s.str("id"), Ids.safeId.matches(id), let seen = s.long("last_seen") {
            session = id
            lastSeen = seen
        }
    }

    /// Whether the session would rotate at [nowMs], without rotating it.
    package func wouldRotate(_ nowMs: Int64) -> Bool {
        if pinnedSession != nil { return false }
        guard session != nil, let seen = lastSeen else { return true }
        return nowMs - seen >= timeoutMillis
    }

    /// The ids for an event at [nowMs] where the visitor was [presence]. An event in the app slides the window and
    /// starts a new session once the last has lapsed; leaving it slides a session still live; anything while away is
    /// filed under the session in force, lapsed or not, and a session one starts because there was none is lapsed
    /// from the outset.
    package func resolve(_ nowMs: Int64, _ presence: Presence = .here) -> Resolved {
        let minted = pinnedDevice == nil && self.device == nil
        if minted { self.device = Ids.uuidV4() }
        let device = pinnedDevice ?? self.device!
        var rotated = false
        let session: String
        let lapsed = wouldRotate(nowMs)
        if let pinned = pinnedSession {
            session = pinned
        } else {
            if self.session == nil || (lapsed && presence == .here) {
                self.session = Ids.uuidV4()
                rotated = true
            }
            session = self.session!
        }
        // A pinned session never lapses, but it is active as any other is, which a web page it is given must know: a
        // last activity of 0 reads as lapsed.
        let slides = presence == .here || (presence == .leaving && !lapsed)
        if slides && (lastSeen == nil || nowMs > lastSeen!) { lastSeen = nowMs }
        dirty = true
        if minted || rotated || writtenAt == nil || abs(nowMs - writtenAt!) >= 1000 { flush(nowMs) }
        return Resolved(device: device, session: session, rotated: rotated)
    }

    /// Writes the ids if they changed and storage is allowed.
    package func flush(_ nowMs: Int64? = nil) {
        if !dirty || !storageAllowed { return }
        var m: JSONObject = ["v": 1]
        if pinnedDevice == nil, let d = device { m["device"] = .string(d) }
        let s = pinnedSession == nil ? session : nil
        if let s = s, let seen = lastSeen { m["session"] = ["id": .string(s), "last_seen": .int(seen)] }
        if store.writeJson(Identity.file, m) {
            dirty = false
            writtenAt = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    /// Forgets the device and session, for `Kontala.reset()` and an opt-out: the next event mints new ones.
    package func forget() {
        device = nil
        session = nil
        lastSeen = nil
        store.delete(Identity.file)
        dirty = true
    }

    /// The device id in force, minting one if none is, which is written at once.
    package var deviceId: String {
        if let p = pinnedDevice { return p }
        if let d = device { return d }
        let d = Ids.uuidV4()
        device = d
        dirty = true
        flush()
        return d
    }

    /// The session in force and when it was last active, without sliding it, which a page is given as it is: nil
    /// before the first event in the app, pinned or not.
    package func sessionNow() -> WebSession? {
        guard let id = pinnedSession ?? session, let seen = lastSeen else { return nil }
        return WebSession(id, seen)
    }

    /// Takes what a web page the app shows said of its visit: its session and when it was last active, read from its
    /// cookie or told through the bridge, under the rule both keep (`mergeSessions`, collector/webview.Merge). One
    /// visit slides to the later of the two; the page's own visit is taken only where it began at least
    /// `timeoutMillis` after the app's last activity, since the app's had lapsed; otherwise the app's stands. Answers
    /// whether the app's session changed. A pinned session is the app's own word, and stands.
    @discardableResult
    package func mergeWeb(_ id: String, _ lastSeen: Int64) -> Bool {
        if pinnedSession != nil || !Ids.safeId.matches(id) { return false }
        if let own = session, let seen = self.lastSeen {
            if own == id {
                if lastSeen <= seen { return false }
                self.lastSeen = lastSeen
            } else if lastSeen - seen >= timeoutMillis {
                session = id
                self.lastSeen = lastSeen
            } else {
                if lastSeen <= seen { return false }
                self.lastSeen = lastSeen
            }
        } else {
            session = id
            self.lastSeen = lastSeen
        }
        dirty = true
        flush()
        return true
    }
}
