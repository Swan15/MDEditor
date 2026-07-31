import XCTest
@testable import MDEditor

/// Round-trips every fixture: parse → build attributed string → serialize.
final class RoundTripTests: XCTestCase {
    /// Fixtures ship as test-bundle resources (synchronized folders copy
    /// them automatically). They must come from the bundle — the sandboxed
    /// test host may not read arbitrary paths on disk.
    func fixtureURLs() throws -> [URL] {
        let urls = Bundle(for: RoundTripTests.self).urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func roundTrip(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    /// Every fixture is written in canonical style and must serialize back
    /// to its exact source.
    func testRoundTripEqualsSource() throws {
        let fixtures = try fixtureURLs()
        XCTAssertFalse(fixtures.isEmpty, "No .md fixtures found in the test bundle")
        for url in fixtures {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(roundTrip(source), source, "Round-trip mismatch in \(url.lastPathComponent)")
        }
    }

    /// Serializing a re-parse of serialized output must be a fixed point.
    func testFixpoint() throws {
        for url in try fixtureURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let once = roundTrip(source)
            XCTAssertEqual(roundTrip(once), once, "No fixpoint for \(url.lastPathComponent)")
        }
    }
}
