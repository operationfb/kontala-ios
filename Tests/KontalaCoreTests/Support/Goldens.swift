import Foundation
import XCTest

@testable import KontalaCore

// The requests scripted sessions send, written as goldens the collector's
// TestSDKRequestsDecode decodes with the Events API's strict decoder
// (collector/internal/api/sdk_requests_test.go), and TestSDKGoldensTellOneStory
// holds to the Flutter SDK's goldens of the same name, row by row.
//
// `KONTALA_UPDATE_GOLDENS=1 swift test` rewrites them; review the diff, then
// run the Go tests.

/// Ids, devices and sessions are random, so a golden names each by the order it first appears in, as the Flutter
/// SDK's do.
func normalise(_ requests: [JSONObject]) -> [JSONObject] {
    var names: [String: String] = [:]
    var counts: [String: Int] = [:]
    func name(_ kind: String, _ value: String) -> String {
        if let n = names["\(kind):\(value)"] { return n }
        counts[kind, default: 0] += 1
        let n = "\(kind)-\(counts[kind]!)"
        names["\(kind):\(value)"] = n
        return n
    }
    return requests.map { r in
        var out = r
        let events: [JSON] = (r.list("events") ?? []).map { raw in
            var e = JSONObject()
            for (k, v) in raw.object ?? JSONObject() {
                switch k {
                case "id", "view": e[k] = .string(name("event", v.string!))
                case "device": e[k] = .string(name("device", v.string!))
                case "session": e[k] = .string(name("session", v.string!))
                default: e[k] = v
                }
            }
            return .object(e)
        }
        out["events"] = .array(events)
        return out
    }
}

/// [value] as Dart's `JsonEncoder.withIndent('  ')` writes it, so the iOS SDK's goldens read like the Flutter SDK's:
/// two spaces, `"key": value`, and an empty object or list on one line.
func pretty(_ value: JSON) -> String {
    var b = ""
    write(&b, value, 0)
    return b
}

private func write(_ b: inout String, _ v: JSON, _ depth: Int) {
    switch v {
    case .object(let o):
        if o.isEmpty {
            b += "{}"
            return
        }
        b += "{\n"
        var first = true
        for (k, x) in o {
            if !first { b += ",\n" }
            first = false
            b += String(repeating: "  ", count: depth + 1)
            b += Json.encode(.string(k)) + ": "
            write(&b, x, depth + 1)
        }
        b += "\n" + String(repeating: "  ", count: depth) + "}"
    case .array(let a):
        if a.isEmpty {
            b += "[]"
            return
        }
        b += "[\n"
        var first = true
        for x in a {
            if !first { b += ",\n" }
            first = false
            b += String(repeating: "  ", count: depth + 1)
            write(&b, x, depth + 1)
        }
        b += "\n" + String(repeating: "  ", count: depth) + "]"
    default:
        b += Json.encode(v)
    }
}

/// What a session sent, held to its golden, or written as it with `KONTALA_UPDATE_GOLDENS=1`.
func holdToGolden(
    _ name: String, _ description: String, capture: JSONObject, refused: [JSON], requests: [JSONObject],
    file: StaticString = #filePath, line: UInt = #line
) {
    let doc: JSONObject = [
        "_comment": .string(description),
        "capture": .object(capture),
        "refused": .array(refused),
        "requests": .array(normalise(requests).map { .object($0) }),
    ]
    let text = pretty(.object(doc)) + "\n"
    let url = repo.appendingPathComponent("sdk/ios/Tests/Goldens/requests/\(name).json")
    if updateGoldens {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    guard let have = try? String(contentsOf: url, encoding: .utf8) else {
        XCTFail("run with KONTALA_UPDATE_GOLDENS=1 to write \(url.path)", file: file, line: line)
        return
    }
    XCTAssertEqual(
        have, text, "\(url.path) differs: run with KONTALA_UPDATE_GOLDENS=1 and review", file: file, line: line)
}
