import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The one clock every event is stamped from, in microseconds since the epoch, as Dart's `DateTime` keeps one.
///
/// An Events API row has no `seq`, and `events_clean` orders two rows of one visit that share a timestamp by their
/// `ingest_id`, which is random: a tap stamped in the same microsecond as its screen could sort before it. So every
/// stamp is strictly later than the one before it.
///
/// The device's clock can be wrong, and the API refuses a timestamp more than 30 days old or 24 hours ahead rather
/// than clamping it. Each response's `Date` header measures the skew; beyond `skewLimitMicros`, an event captured in
/// this process is restamped at send time from the monotonic clock, anchored to the server's.
///
/// A test's `wallMicros` drives every duration too (`elapsedMicros`), as the Flutter SDK's fake clock does.
package final class Clock {
    package static let skewLimitMicros: Int64 = 10 * 60 * 1_000_000

    private let faked: Bool
    private let wall: () -> Int64
    private let monotonicNanos: () -> Int64
    private let startNanos: Int64
    package let startedAtMicros: Int64
    private var lastMicros: Int64 = 0
    private var skewMicros: Int64?

    package init(wallMicros: (() -> Int64)? = nil, monotonicNanos: (() -> Int64)? = nil) {
        faked = wallMicros != nil
        wall = wallMicros ?? Clock.systemMicros
        self.monotonicNanos = monotonicNanos ?? Clock.systemMonotonicNanos
        startNanos = self.monotonicNanos()
        startedAtMicros = wall()
    }

    /// The device's own time, strictly later than the last stamp.
    package func stamp() -> Int64 {
        var m = wall()
        if m <= lastMicros { m = lastMicros + 1 }
        lastMicros = m
        return m
    }

    /// Microseconds on the monotonic clock, which a changed wall clock does not move.
    package var monotonicMicros: Int64 { (monotonicNanos() - startNanos) / 1000 }

    /// Time since the clock started, which every duration the SDK measures is read from.
    package var elapsedMicros: Int64 { faked ? wall() - startedAtMicros : monotonicMicros }

    /// The device's time now, without moving the stamp order.
    package func nowMicros() -> Int64 { wall() }

    package func nowMillis() -> Int64 { floorDiv(wall(), 1000) }

    /// Records the skew a response's `Date` header shows.
    package func observeServerTime(_ serverMillis: Int64) {
        skewMicros = serverMillis * 1000 - nowMicros()
    }

    /// Whether the device's clock is off by more than `skewLimitMicros`.
    package var skewed: Bool {
        guard let s = skewMicros else { return false }
        return abs(s) > Clock.skewLimitMicros
    }

    /// An event's timestamp as it is sent: the time captured, unless the clock is `skewed` and the event was captured
    /// in this process, when it is the server's time of the moment it was captured.
    package func sendTime(_ capturedMicros: Int64, _ capturedMonotonic: Int64?) -> Int64 {
        guard let skew = skewMicros, abs(skew) > Clock.skewLimitMicros, let captured = capturedMonotonic else {
            return capturedMicros
        }
        let elapsed = monotonicMicros - captured
        return nowMicros() + skew - elapsed
    }

    private static func systemMicros() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1000
    }

    private static func systemMonotonicNanos() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}

/// [a] divided by [b], rounded towards negative infinity.
package func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

/// [a] modulo [b], with the sign of [b].
package func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
    a - floorDiv(a, b) * b
}

private func pad(_ n: Int64, _ width: Int) -> String {
    let s = String(n)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}

/// RFC 3339 in UTC with microseconds, which the API parses (`time.RFC3339Nano`) and BigQuery keeps to the
/// microsecond.
package func rfc3339(_ micros: Int64) -> String {
    let days = floorDiv(micros, 86_400_000_000)
    let inDay = floorMod(micros, 86_400_000_000)
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468
    let era = floorDiv(z, 146_097)
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    let seconds = inDay / 1_000_000
    let fraction = inDay % 1_000_000
    return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" + pad(seconds / 3600, 2) + ":"
        + pad(seconds / 60 % 60, 2) + ":" + pad(seconds % 60, 2) + "." + pad(fraction, 6) + "Z"
}

private let httpDateFormats = [
    "EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy",
]

/// An HTTP date (`Date`, `Retry-After`), RFC 7231's IMF-fixdate and its two obsolete forms, in milliseconds since the
/// epoch, or nil.
package func parseHttpDate(_ value: String) -> Int64? {
    let text = value.trimmingCharacters(in: .whitespaces)
    for format in httpDateFormats {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.isLenient = false
        f.dateFormat = format
        if let d = f.date(from: text) {
            return Int64((d.timeIntervalSince1970 * 1000).rounded())
        }
    }
    return nil
}
