import Foundation

// The Events API's own limits and patterns (collector/internal/api/build.go
// and request.go). Every value is held to them before it is queued, because
// one value the API refuses refuses the whole event, and an unknown field or
// a wrong JSON type refuses the whole request. sdk/testdata/vectors.json holds
// every rule here to the Flutter SDK's answers.

/// A regular expression held to the whole of a string, as Kotlin's `Regex.matches` holds one.
package struct Pattern {
    private let re: NSRegularExpression

    package init(_ pattern: String) {
        re = try! NSRegularExpression(pattern: pattern)
    }

    /// Whether the whole of [s] matches.
    package func matches(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [.anchored], range: range) else { return false }
        return m.range == range
    }
}

package enum Limits {
    /// `appVerRe`: an app's version and build.
    package static let appVersion = Pattern("^[A-Za-z0-9][A-Za-z0-9._+ ()-]{0,63}$")

    /// `localeRe`: a language tag.
    package static let locale = Pattern("^[A-Za-z]{2,8}([-_][A-Za-z0-9]{1,8}){0,4}$")

    /// `hostRe` applied to an app's id as `appHost` reads it: lower case, with `_` read as `-`.
    package static let appHost = Pattern("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")

    package static let maxScreenName = 200  // code points
    package static let maxURL = 2048
    package static let maxText = 255  // code points, clicks.MaxText
    package static let maxAttribute = 500  // bytes, clicks.MaxAttributeValue
    package static let maxPath = 512  // code points, clicks.MaxPath
    package static let maxUserAgent = 1024
    package static let maxDisplay = 100_000
    package static let maxEventsPerRequest = 200
    package static let maxPropertiesBytes = 64 * 1024
}

/// The number of code points in [s].
package func codePointCount(_ s: String) -> Int { s.unicodeScalars.count }

/// Whether code point [r] is printable as Go's `unicode.IsPrint` reads it, which is what the API's `printable` asks:
/// no control or format character, and no space but the ASCII one.
package func printableRune(_ r: UInt32) -> Bool {
    if r < 0x20 || (0x7F...0xA0).contains(r) { return false }
    if r == 0xAD || r == 0x1680 || r == 0x180E || r == 0x3000 { return false }
    if (0x2000...0x200F).contains(r) { return false }  // spaces, zero widths, marks
    if (0x2028...0x202F).contains(r) { return false }  // separators, embeddings
    if (0x205F...0x206F).contains(r) { return false }  // math space, invisibles
    if r == 0xFEFF || (0xFFF9...0xFFFB).contains(r) { return false }
    if (0xD800...0xDFFF).contains(r) { return false }  // lone surrogates
    if (0xE0000...0xE007F).contains(r) { return false }  // tags
    return true
}

/// Whether every code point of [s] is printable.
package func printable(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { printableRune($0.value) }
}

/// Whether [r] is whitespace as Dart's `String.trim` reads it: Unicode's White_Space and U+FEFF. Never U+001C to
/// U+001F, which Java calls whitespace and Dart drops as controls, nor U+180E or U+200B, which Dart keeps.
package func isTrimSpace(_ r: UInt32) -> Bool {
    if r <= 0x20 { return r == 0x20 || (0x09...0x0D).contains(r) }
    if r == 0x85 || r == 0xA0 || r == 0x1680 { return true }
    if (0x2000...0x200A).contains(r) { return true }
    return r == 0x2028 || r == 0x2029 || r == 0x202F || r == 0x205F || r == 0x3000 || r == 0xFEFF
}

/// [s] with every code point that is not printable read as a space, collapsed, trimmed and cut to [max] code points,
/// so a name the API would refuse is sent as the nearest name it takes.
package func printableText(_ s: String, _ max: Int) -> String {
    var b = String.UnicodeScalarView()
    for u in s.unicodeScalars { b.append(printableRune(u.value) ? u : " ") }
    return collapse(String(b), max)
}

/// [s] cut to at most [max] code points.
package func cutRunes(_ s: String, _ max: Int) -> String {
    if max <= 0 { return "" }
    let scalars = s.unicodeScalars
    if scalars.count <= max { return s }
    return String(String.UnicodeScalarView(scalars.prefix(max)))
}

/// [s] with every run of whitespace one space, control characters dropped, trimmed, and cut to [max] code points, as
/// `clicks.Collapse` keeps text.
package func collapse(_ s: String, _ max: Int) -> String {
    var b = String.UnicodeScalarView()
    var space = false
    for u in s.unicodeScalars {
        let r = u.value
        if isTrimSpace(r) {
            space = !b.isEmpty
            continue
        }
        if r < 0x20 || (0x7F..<0xA0).contains(r) { continue }
        if space { b.append(" ") }
        space = false
        b.append(u)
    }
    return cutRunes(String(b), max)
}

/// [s] cut to at most [max] UTF-8 bytes without splitting a character.
package func cutBytes(_ s: String, _ max: Int) -> String {
    var bytes = 0
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        let n = UTF8.width(u)
        if bytes + n > max { break }
        bytes += n
        out.append(u)
    }
    return String(out)
}

/// The UTF-8 length of [s].
package func utf8Length(_ s: String) -> Int { s.utf8.count }

/// [s] decoded as one component of a query, as Dart's `Uri.decodeQueryComponent` decodes it, or nil where Dart throws:
/// a character past ASCII written raw, an escape that is not two hex digits, or bytes that are not UTF-8.
package func decodeQueryComponent(_ s: String) -> String? {
    let raw = Array(s.utf8)
    if !raw.contains(where: { $0 > 127 || $0 == UInt8(ascii: "%") || $0 == UInt8(ascii: "+") }) { return s }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(raw.count)
    var i = 0
    while i < raw.count {
        let c = raw[i]
        if c > 127 { return nil }
        if c == UInt8(ascii: "%") {
            if i + 3 > raw.count { return nil }
            guard let hi = hexDigit(raw[i + 1]), let lo = hexDigit(raw[i + 2]) else { return nil }
            bytes.append(hi * 16 + lo)
            i += 2
        } else if c == UInt8(ascii: "+") {
            bytes.append(0x20)
        } else {
            bytes.append(c)
        }
        i += 1
    }
    return strictUTF8(bytes)
}

private func hexDigit(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

/// [bytes] read as UTF-8, or nil where they are not: an overlong form or a surrogate included.
package func strictUTF8(_ bytes: [UInt8]) -> String? {
    var scalars = String.UnicodeScalarView()
    var it = bytes.makeIterator()
    var decoder = UTF8()
    while true {
        switch decoder.decode(&it) {
        case .scalarValue(let u): scalars.append(u)
        case .emptyInput: return String(scalars)
        case .error: return nil
        }
    }
}

/// The pairs of a query string Go's `url.ParseQuery` takes, in their order: a pair holding `;`, or an escape that does
/// not decode, refuses the whole query there, and so the page view.
package func cleanQuery(_ query: String?) -> String? {
    guard let query = query else { return nil }
    var q = Substring(query)
    if q.hasPrefix("?") { q = q.dropFirst() }
    if let hash = q.firstIndex(of: "#") { q = q[..<hash] }
    var kept: [Substring] = []
    for pair in q.split(separator: "&", omittingEmptySubsequences: false) {
        if pair.isEmpty || pair.contains(";") { continue }
        let eq = pair.firstIndex(of: "=")
        if decodeQueryComponent(String(eq.map { pair[..<$0] } ?? pair)) == nil { continue }
        if let eq = eq, decodeQueryComponent(String(pair[pair.index(after: eq)...])) == nil { continue }
        if !printable(String(pair)) { continue }
        kept.append(pair)
    }
    let out = kept.joined(separator: "&")
    // A length in UTF-16 code units, as Dart's String.length counts.
    if out.isEmpty || out.utf16.count > Limits.maxURL { return nil }
    return out
}
