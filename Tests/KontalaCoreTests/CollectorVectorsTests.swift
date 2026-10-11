import Foundation
import XCTest

@testable import KontalaCore

/// The collector's own vectors, which the tag's and the other SDKs' tests read too: a type the collector adds fails
/// this suite until the SDK has it.
final class CollectorVectorsTests: XCTestCase {
    private func codes(_ path: String, _ key: String) -> [String] {
        (repoJson(path).list(key) ?? []).map { $0.string! }
    }

    func testPageTypesAreTheCollectorsVocabularyInItsOrder() {
        XCTAssertEqual(
            codes("collector/pagesignals/testdata/vectors.json", "page_types"), KontalaPageType.allCases.map(\.wire))
    }

    func testClickTypesAreTheCollectorsVocabularyInItsOrder() {
        XCTAssertEqual(
            codes("collector/clicks/testdata/vectors.json", "click_types"), KontalaClickType.allCases.map(\.wire))
    }

    func testTheNamesACustomEventMayNotTakeAreTheApisReservedOnes() throws {
        let source = try String(
            contentsOf: repo.appendingPathComponent("collector/internal/api/build.go"), encoding: .utf8)
        let block = try NSRegularExpression(pattern: "var reserved = map\\[string\\]bool\\{([^}]*)\\}")
        let m = try XCTUnwrap(block.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let inner = String(source[Range(m.range(at: 1), in: source)!])
        let name = try NSRegularExpression(pattern: "\"([a-z_]+)\": true")
        let names = Set(
            name.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)).map {
                String(inner[Range($0.range(at: 1), in: inner)!])
            })
        XCTAssertEqual(names, reservedEventNames)
        XCTAssertEqual("page_view", canonicalEventName("Page View"))
        XCTAssertEqual("add_to_cart", canonicalEventName("add-to-cart!"))
    }
}
