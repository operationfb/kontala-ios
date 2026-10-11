package enum Ids {
    /// The pattern the collector holds a device and a session id to (collector/internal/event/event.go `SafeID`). A `.`
    /// is outside it on purpose: the web's session cookie uses it as its separator.
    package static let safeId = Pattern("^[A-Za-z0-9_-]{1,128}$")

    /// The pattern a principal id is held to on both sides (`SAFE_PRINCIPAL_ID` in tag/core/core.user.ts,
    /// `event.PrincipalID`): an app's own id or an email address.
    package static let safePrincipalId = Pattern("^[A-Za-z0-9_.@+-]{1,254}$")

    /// A random UUID, version 4: a device's or a session's id, which says nothing about when it was made.
    package static func uuidV4() -> String {
        var b = randomBytes()
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return format(b)
    }

    /// A UUID, version 7: an event's id, ordered by the millisecond it was captured in, so a queue and a log read in
    /// time order.
    package static func uuidV7(_ unixMillis: Int64) -> String {
        var b = randomBytes()
        for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: unixMillis >> (8 * (5 - Int64(i)))) }
        b[6] = (b[6] & 0x0F) | 0x70
        b[8] = (b[8] & 0x3F) | 0x80
        return format(b)
    }

    /// Sixteen bytes from the system's cryptographic generator.
    private static func randomBytes() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for _ in 0..<2 {
            let x = g.next() as UInt64
            for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: x >> (8 * UInt64(i)))) }
        }
        return out
    }

    private static let hex: [Character] = Array("0123456789abcdef")

    private static func format(_ b: [UInt8]) -> String {
        var h = ""
        h.reserveCapacity(36)
        for (i, x) in b.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 { h.append("-") }
            h.append(hex[Int(x >> 4)])
            h.append(hex[Int(x & 0x0F)])
        }
        return h
    }
}
