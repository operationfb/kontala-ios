import Foundation

/// A JSON value as the SDK holds one: an object keeps its keys in the order they were first set, a whole number is an
/// `Int64` and any other number a `Double`, as the Dart SDK's maps hold them.
///
/// The SDK's one JSON codec is its own rather than Foundation's, because `JSONSerialization` keeps no key order and
/// writes `/` as `\/`; this one writes what Dart's `jsonEncode` writes, which the request goldens of every SDK are
/// compared on.
package enum JSON {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// A JSON object: its keys in the order they were first set, as Kotlin's `LinkedHashMap` and Dart's maps keep them.
/// Setting a key already there keeps its place.
package struct JSONObject {
    package private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    package init() {}

    package init(_ pairs: [(String, JSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    package subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let value = newValue {
                if storage.updateValue(value, forKey: key) == nil { keys.append(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    package mutating func removeValue(forKey key: String) -> JSON? {
        guard let old = storage.removeValue(forKey: key) else { return nil }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        return old
    }

    package mutating func removeAll() {
        keys.removeAll()
        storage.removeAll()
    }

    package var count: Int { keys.count }
    package var isEmpty: Bool { keys.isEmpty }
    package func contains(_ key: String) -> Bool { storage[key] != nil }

    /// The values in their keys' order.
    package var values: [JSON] { keys.map { storage[$0]! } }

    /// The object at [key], or nil.
    package func obj(_ key: String) -> JSONObject? { self[key]?.object }

    /// The whole number at [key], or nil.
    package func long(_ key: String) -> Int64? { self[key]?.int }

    /// The string at [key], or nil.
    package func str(_ key: String) -> String? { self[key]?.string }

    /// The list at [key], or nil.
    package func list(_ key: String) -> [JSON]? { self[key]?.array }

    /// The object with only the entries [keep] answers true for, in their order.
    package func filter(_ keep: (String, JSON) -> Bool) -> JSONObject {
        var out = JSONObject()
        for k in keys where keep(k, storage[k]!) { out[k] = storage[k]! }
        return out
    }

    /// The object with every value [transform] answers, in their order.
    package func mapValues(_ transform: (JSON) -> JSON) -> JSONObject {
        var out = JSONObject()
        for k in keys { out[k] = transform(storage[k]!) }
        return out
    }
}

extension JSONObject: Sequence {
    package func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var i = 0
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    package init(dictionaryLiteral elements: (String, JSON)...) {
        self.init(elements)
    }
}

/// Two objects are equal when they hold the same keys with equal values, in any order, as two maps are.
extension JSONObject: Equatable {
    package static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.storage == b.storage
    }
}

/// Values are equal as Kotlin's maps compare them: a whole number is never equal to a double, and objects are compared
/// by their contents whatever their order. `jsonEquals` compares numbers as numbers.
extension JSON: Equatable {
    package static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y || (x.isNaN && y.isNaN)
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x == y
        default: return false
        }
    }
}

extension JSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(integerLiteral value: Int64) { self = .int(value) }
    package init(floatLiteral value: Double) { self = .double(value) }
    package init(stringLiteral value: String) { self = .string(value) }
    package init(arrayLiteral elements: JSON...) { self = .array(elements) }
    package init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

extension JSON {
    package var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A whole number, as Kotlin's `long` reads one: never a double, however whole.
    package var int: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// Any number, as a double.
    package var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    package var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    package var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    package var object: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    package var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    package var isNumber: Bool { number != nil }

    /// A string or nil, as `JSON?` from an optional string.
    package init(_ s: String?) {
        self = s.map { .string($0) } ?? .null
    }
}

package struct JSONError: Error, CustomStringConvertible {
    package let description: String
    package init(_ message: String) { description = message }
}

package enum Json {
    /// [value] as JSON text. A number that is not finite is written as null.
    package static func encode(_ value: JSON) -> String {
        var out = ""
        write(&out, value)
        return out
    }

    /// [value] as JSON text, an object.
    package static func encode(_ value: JSONObject) -> String {
        encode(.object(value))
    }

    /// [text] read as JSON, or a `JSONError` where it is not JSON.
    package static func decode(_ text: String) throws -> JSON {
        var r = Reader(Array(text.utf8))
        r.space()
        let v = try r.value(0)
        r.space()
        if !r.done { throw JSONError("trailing text at \(r.at)") }
        return v
    }

    /// [data] read as UTF-8 JSON, or a `JSONError`.
    package static func decode(_ data: Data) throws -> JSON {
        var r = Reader(Array(data))
        r.space()
        let v = try r.value(0)
        r.space()
        if !r.done { throw JSONError("trailing text at \(r.at)") }
        return v
    }

    /// [text] read as a JSON object, or nil for anything else.
    package static func decodeObject(_ text: String) -> JSONObject? {
        (try? decode(text))?.object
    }

    /// [data] read as a JSON object, or nil for anything else.
    package static func decodeObject(_ data: Data) -> JSONObject? {
        (try? decode(data))?.object
    }

    private static func write(_ b: inout String, _ v: JSON) {
        switch v {
        case .null: b += "null"
        case .bool(let x): b += x ? "true" : "false"
        case .int(let x): b += String(x)
        case .double(let x): b += x.isFinite ? dartDouble(x) : "null"
        case .string(let s): string(&b, s)
        case .array(let a):
            b += "["
            var first = true
            for x in a {
                if !first { b += "," }
                first = false
                write(&b, x)
            }
            b += "]"
        case .object(let o):
            b += "{"
            var first = true
            for (k, x) in o {
                if !first { b += "," }
                first = false
                string(&b, k)
                b += ":"
                write(&b, x)
            }
            b += "}"
        }
    }

    /// A finite double as Dart writes one: the shortest digits that read back as it, `79.5`, `700.0`, and an exponent
    /// only below 1e-6 or from 1e21 on, `1e-7` and `1e+21`.
    package static func dartDouble(_ d: Double) -> String {
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        // Swift's description holds the shortest digits that read back as d,
        // in a notation of its own choosing.
        let s = abs(d).description
        var mantissa = Substring(s)
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = s[..<e]
            exponent = Int(s[s.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        var digits = Array(whole + fraction)
        // d is 0.<digits> times ten to point.
        var point = whole.count + exponent
        while let first = digits.first, first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while let last = digits.last, last == "0" { digits.removeLast() }
        if digits.isEmpty { return d.sign == .minus ? "-0.0" : "0.0" }
        let sign = d < 0 ? "-" : ""
        let e = point - 1
        if e >= -6 && e < 21 {
            if point <= 0 {
                return sign + "0." + String(repeating: "0", count: -point) + String(digits)
            }
            if point >= digits.count {
                return sign + String(digits) + String(repeating: "0", count: point - digits.count) + ".0"
            }
            return sign + String(digits[..<point]) + "." + String(digits[point...])
        }
        var out = sign + String(digits[0])
        if digits.count > 1 { out += "." + String(digits[1...]) }
        out += e < 0 ? "e-\(-e)" : "e+\(e)"
        return out
    }

    private static let hex: [Character] = Array("0123456789abcdef")

    private static func string(_ b: inout String, _ s: String) {
        b += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": b += "\\\""
            case "\\": b += "\\\\"
            case "\n": b += "\\n"
            case "\r": b += "\\r"
            case "\t": b += "\\t"
            case "\u{08}": b += "\\b"
            case "\u{0C}": b += "\\f"
            default:
                if u.value < 0x20 {
                    b += "\\u00"
                    b.append(hex[Int(u.value >> 4)])
                    b.append(hex[Int(u.value & 0xF)])
                } else {
                    b.unicodeScalars.append(u)
                }
            }
        }
        b += "\""
    }

    private struct Reader {
        let s: [UInt8]
        var at = 0

        init(_ s: [UInt8]) { self.s = s }

        var done: Bool { at >= s.count }

        mutating func space() {
            while at < s.count && (s[at] == 0x20 || s[at] == 0x0A || s[at] == 0x0D || s[at] == 0x09) { at += 1 }
        }

        mutating func value(_ depth: Int) throws -> JSON {
            if depth > 512 { throw JSONError("nested too deep") }
            if done { throw JSONError("unexpected end") }
            let c = s[at]
            switch c {
            case UInt8(ascii: "{"): return .object(try obj(depth))
            case UInt8(ascii: "["): return .array(try arr(depth))
            case UInt8(ascii: "\""): return .string(try str())
            case UInt8(ascii: "t"): return try word("true", .bool(true))
            case UInt8(ascii: "f"): return try word("false", .bool(false))
            case UInt8(ascii: "n"): return try word("null", .null)
            default:
                if c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) { return try num() }
                throw JSONError("unexpected '\(Character(Unicode.Scalar(c)))' at \(at)")
            }
        }

        private mutating func word(_ w: String, _ v: JSON) throws -> JSON {
            let bytes = Array(w.utf8)
            if at + bytes.count > s.count || Array(s[at..<at + bytes.count]) != bytes {
                throw JSONError("unexpected text at \(at)")
            }
            at += bytes.count
            return v
        }

        private mutating func obj(_ depth: Int) throws -> JSONObject {
            var m = JSONObject()
            at += 1
            space()
            if !done && s[at] == UInt8(ascii: "}") {
                at += 1
                return m
            }
            while true {
                space()
                if done || s[at] != UInt8(ascii: "\"") { throw JSONError("expected a key at \(at)") }
                let k = try str()
                space()
                if done || s[at] != UInt8(ascii: ":") { throw JSONError("expected ':' at \(at)") }
                at += 1
                space()
                m[k] = try value(depth + 1)
                space()
                if done { throw JSONError("unexpected end") }
                switch s[at] {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "}"):
                    at += 1
                    return m
                default: throw JSONError("expected ',' or '}' at \(at)")
                }
            }
        }

        private mutating func arr(_ depth: Int) throws -> [JSON] {
            var l: [JSON] = []
            at += 1
            space()
            if !done && s[at] == UInt8(ascii: "]") {
                at += 1
                return l
            }
            while true {
                space()
                l.append(try value(depth + 1))
                space()
                if done { throw JSONError("unexpected end") }
                switch s[at] {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "]"):
                    at += 1
                    return l
                default: throw JSONError("expected ',' or ']' at \(at)")
                }
            }
        }

        private mutating func hex4() throws -> UInt32 {
            if at + 4 > s.count { throw JSONError("short unicode escape") }
            var code: UInt32 = 0
            for i in 0..<4 {
                let c = s[at + i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw JSONError("bad unicode escape at \(at)")
                }
                code = code * 16 + d
            }
            at += 4
            return code
        }

        private mutating func str() throws -> String {
            at += 1
            var bytes: [UInt8] = []
            while true {
                if done { throw JSONError("unterminated string") }
                let c = s[at]
                at += 1
                if c == UInt8(ascii: "\"") {
                    return String(decoding: bytes, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    if done { throw JSONError("unterminated escape") }
                    let e = s[at]
                    at += 1
                    switch e {
                    case UInt8(ascii: "\""): bytes.append(0x22)
                    case UInt8(ascii: "\\"): bytes.append(0x5C)
                    case UInt8(ascii: "/"): bytes.append(0x2F)
                    case UInt8(ascii: "b"): bytes.append(0x08)
                    case UInt8(ascii: "f"): bytes.append(0x0C)
                    case UInt8(ascii: "n"): bytes.append(0x0A)
                    case UInt8(ascii: "r"): bytes.append(0x0D)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if code >= 0xD800 && code < 0xDC00 && at + 6 <= s.count && s[at] == UInt8(ascii: "\\")
                            && s[at + 1] == UInt8(ascii: "u")
                        {
                            let save = at
                            at += 2
                            let low = try hex4()
                            if low >= 0xDC00 && low < 0xE000 {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                at = save
                            }
                        }
                        // A lone surrogate is no character a Swift string can hold.
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default:
                        throw JSONError("bad escape '\\\(Character(Unicode.Scalar(e)))'")
                    }
                } else if c < 0x20 {
                    throw JSONError("control character in a string")
                } else {
                    bytes.append(c)
                }
            }
        }

        private mutating func num() throws -> JSON {
            let start = at
            if s[at] == UInt8(ascii: "-") { at += 1 }
            while at < s.count && s[at] >= 0x30 && s[at] <= 0x39 { at += 1 }
            var whole = true
            if at < s.count && s[at] == UInt8(ascii: ".") {
                whole = false
                at += 1
                while at < s.count && s[at] >= 0x30 && s[at] <= 0x39 { at += 1 }
            }
            if at < s.count && (s[at] == UInt8(ascii: "e") || s[at] == UInt8(ascii: "E")) {
                whole = false
                at += 1
                if at < s.count && (s[at] == UInt8(ascii: "+") || s[at] == UInt8(ascii: "-")) { at += 1 }
                while at < s.count && s[at] >= 0x30 && s[at] <= 0x39 { at += 1 }
            }
            let text = String(decoding: s[start..<at], as: UTF8.self)
            if text == "-" || text.isEmpty { throw JSONError("bad number at \(start)") }
            if whole, let i = Int64(text) { return .int(i) }
            guard let d = Double(text) else { throw JSONError("bad number '\(text)'") }
            return .double(d)
        }
    }
}

/// Numbers compared as numbers, objects and lists by their contents.
package func jsonEquals(_ a: JSON, _ b: JSON) -> Bool {
    switch (a, b) {
    case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
        return a.number! == b.number!
    case (.object(let x), .object(let y)):
        return x.count == y.count && x.allSatisfy { k, v in y[k].map { jsonEquals(v, $0) } ?? false }
    case (.array(let x), .array(let y)):
        return x.count == y.count && zip(x, y).allSatisfy { jsonEquals($0, $1) }
    default:
        return a == b
    }
}
