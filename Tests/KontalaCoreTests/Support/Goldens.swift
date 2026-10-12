import Foundation
import KontalaTestSupport
import XCTest

@testable import KontalaCore

/// What a session sent, held to its golden (`goldenMismatch`, which KontalaTestSupport has), or written as it with
/// `KONTALA_UPDATE_GOLDENS=1`.
func holdToGolden(
    _ name: String, _ description: String, capture: JSONObject, refused: [JSON], requests: [JSONObject],
    file: StaticString = #filePath, line: UInt = #line
) {
    if let wrong = goldenMismatch(name, description, capture: capture, refused: refused, requests: requests) {
        XCTFail(wrong, file: file, line: line)
    }
}
