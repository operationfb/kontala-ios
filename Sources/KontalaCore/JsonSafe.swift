import Foundation

#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// [value] as JSON the Events API takes as data layer data: a date as RFC 3339, an enum by its raw value or its case's
/// name, a URL or a UUID as text, a duration in milliseconds, a number that is not finite dropped, a dictionary's keys
/// as text and in their order, and anything else dropped, 16 levels deep at most. Answers nil for a value dropped, and
/// `.null` for a nil.
package func jsonSafe(_ value: Any?, depth: Int = 0, log: ((String) -> Void)? = nil) -> JSON? {
    if depth > 16 { return nil }
    guard let v = unwrapped(value) else { return .null }
    switch v {
    case let j as JSON: return safeJSON(j, depth, log)
    case let o as JSONObject: return safeJSON(.object(o), depth, log)
    case is NSNull: return .null
    default: break
    }
    let t = type(of: v)
    if t == Bool.self { return .bool(v as! Bool) }
    if t == String.self { return .string(v as! String) }
    if t == Substring.self { return .string(String(v as! Substring)) }
    if t == Character.self { return .string(String(v as! Character)) }
    if t == Int.self { return .int(Int64(v as! Int)) }
    if t == Int8.self { return .int(Int64(v as! Int8)) }
    if t == Int16.self { return .int(Int64(v as! Int16)) }
    if t == Int32.self { return .int(Int64(v as! Int32)) }
    if t == Int64.self { return .int(v as! Int64) }
    if t == UInt8.self { return .int(Int64(v as! UInt8)) }
    if t == UInt16.self { return .int(Int64(v as! UInt16)) }
    if t == UInt32.self { return .int(Int64(v as! UInt32)) }
    if t == UInt.self { return unsigned(UInt64(v as! UInt)) }
    if t == UInt64.self { return unsigned(v as! UInt64) }
    if t == Double.self { return finite(v as! Double) }
    // A float as it reads: 0.1 is 0.1, not 0.10000000149011612.
    if t == Float.self { return finite(Double("\(v as! Float)") ?? .nan) }
    if t == CGFloat.self { return finite(Double(v as! CGFloat)) }
    if t == Decimal.self { return finite(NSDecimalNumber(decimal: v as! Decimal).doubleValue) }
    if let n = v as? NSNumber, t is NSNumber.Type { return number(n) }
    if let d = v as? Date { return .string(rfc3339(Int64((d.timeIntervalSince1970 * 1_000_000).rounded()))) }
    if let u = v as? URL { return .string(u.absoluteString) }
    if let u = v as? UUID { return .string(u.uuidString.lowercased()) }
    if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *), let d = v as? Duration {
        let (seconds, attoseconds) = d.components
        return .int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
    if let r = v as? any RawRepresentable { return jsonSafe(r.rawValue, depth: depth, log: log) }
    if let d = v as? [AnyHashable: Any] { return object(d, depth, log) }
    if let a = v as? [Any] { return .array(a.map { jsonSafe($0, depth: depth + 1, log: log) ?? .null }) }
    if let s = v as? Set<AnyHashable> {
        // A set has no order: its members are sent in the order of their text.
        let members = s.map { jsonSafe($0.base, depth: depth + 1, log: log) ?? .null }
        return .array(members.sorted { Json.encode($0) < Json.encode($1) })
    }
    let m = Mirror(reflecting: v)
    if m.displayStyle == .enum {
        return .string(m.children.first?.label ?? String(describing: v))
    }
    log?("a property of type \(t) is not JSON, and was left out")
    return nil
}

/// [value] with every optional around it taken away, nil for one that holds nothing.
private func unwrapped(_ value: Any?) -> Any? {
    guard let v = value else { return nil }
    let m = Mirror(reflecting: v)
    guard m.displayStyle == .optional else { return v }
    guard let child = m.children.first else { return nil }
    return unwrapped(child.value)
}

private func finite(_ d: Double) -> JSON? { d.isFinite ? .double(d) : nil }

private func unsigned(_ u: UInt64) -> JSON? {
    u <= UInt64(Int64.max) ? .int(Int64(u)) : finite(Double(u))
}

private func number(_ n: NSNumber) -> JSON? {
    #if canImport(Darwin)
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
    #endif
    switch String(cString: n.objCType) {
    case "c" where n.int8Value == 0 || n.int8Value == 1:
        #if canImport(Darwin)
            return .int(Int64(n.int8Value))
        #else
            return .bool(n.boolValue)
        #endif
    case "d": return finite(n.doubleValue)
    case "f": return finite(Double("\(n.floatValue)") ?? .nan)
    case "Q", "L": return unsigned(n.uint64Value)
    default: return .int(n.int64Value)
    }
}

/// A dictionary's entries, its keys as text: a Swift dictionary has no order, so they are sent in their keys' order.
private func object(_ d: [AnyHashable: Any], _ depth: Int, _ log: ((String) -> Void)?) -> JSON {
    var entries: [(String, Any)] = []
    for (k, x) in d { entries.append(("\(k.base)", x)) }
    entries.sort { $0.0 < $1.0 }
    var out = JSONObject()
    for (k, x) in entries {
        if let s = jsonSafe(x, depth: depth + 1, log: log) {
            out[k] = s
        } else if unwrapped(x) == nil {
            out[k] = .null
        }
    }
    return .object(out)
}

/// A JSON value held to the same rules: 16 levels at most, and no number that is not finite.
private func safeJSON(_ j: JSON, _ depth: Int, _ log: ((String) -> Void)?) -> JSON? {
    switch j {
    case .double(let d): return finite(d)
    case .array(let a):
        return .array(a.map { (depth + 1 > 16 ? nil : safeJSON($0, depth + 1, log)) ?? .null })
    case .object(let o):
        var out = JSONObject()
        for (k, x) in o {
            if depth + 1 <= 16, let s = safeJSON(x, depth + 1, log) {
                out[k] = s
            } else if x.isNull {
                out[k] = .null
            }
        }
        return .object(out)
    default: return j
    }
}

/// [properties] as the API takes them, or nil when nothing is left or the whole is over the API's 64 KiB, which it
/// would refuse the event for.
package func safeProperties(_ properties: JSONObject?, log: ((String) -> Void)? = nil) -> JSONObject? {
    guard let p = properties, !p.isEmpty else { return nil }
    guard let out = jsonSafe(JSON.object(p), log: log)?.object, !out.isEmpty else { return nil }
    let bytes = utf8Length(Json.encode(out))
    if bytes > Limits.maxPropertiesBytes {
        log?(
            "properties of \(bytes) bytes are over the API's \(Limits.maxPropertiesBytes >> 10) KiB, and were left out")
        return nil
    }
    return out
}

/// An app's properties as the core keeps them, each dropped value's note given to [log].
package func safeProperties(_ properties: [String: Any]?, log: ((String) -> Void)? = nil) -> JSONObject? {
    guard let p = properties, !p.isEmpty else { return nil }
    return safeProperties(jsonSafe(p, log: log)?.object, log: log)
}

extension JSON {
    /// The value as Foundation holds one, for an app's own code: an object as a dictionary, a list as an array.
    package var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(truncatingIfNeeded: i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundation }
        case .object(let o): return o.foundation
        }
    }
}

extension JSONObject {
    /// The object as a dictionary, for an app's own code.
    package var foundation: [String: Any] {
        var d: [String: Any] = [:]
        for (k, v) in self { d[k] = v.foundation }
        return d
    }
}
