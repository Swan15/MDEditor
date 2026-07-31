import XCTest
@testable import MDEditor

/// Status-bar statistics: word and character counts that skip the editor's
/// placeholder characters (attachment objects, rule NBSPs, line separators).
final class TextStatisticsTests: XCTestCase {
    func testPlainText() {
        XCTAssertEqual(TextStatistics.wordCount("hello world"), 2)
        XCTAssertEqual(TextStatistics.characterCount("hello world"), 11)
    }

    func testEmpty() {
        XCTAssertEqual(TextStatistics.wordCount(""), 0)
        XCTAssertEqual(TextStatistics.characterCount(""), 0)
    }

    func testLineSeparatorSplitsWordsButIsNotACharacter() {
        XCTAssertEqual(TextStatistics.wordCount("a\u{2028}b"), 2)
        XCTAssertEqual(TextStatistics.characterCount("a\u{2028}b"), 2)
    }

    func testPlaceholdersCountAsNothing() {
        XCTAssertEqual(TextStatistics.wordCount("\u{FFFC}\u{00A0}"), 0)
        XCTAssertEqual(TextStatistics.characterCount("\u{FFFC}\u{00A0}"), 0)
    }

    func testMultipleParagraphsAndWhitespace() {
        XCTAssertEqual(TextStatistics.wordCount("one\ntwo  three\n\nfour"), 4)
    }

    func testDocumentShapedText() {
        // "Title" + rule placeholder + "some words" as the storage would hold them.
        let text = "Title\n\u{FFFC}\nsome words"
        XCTAssertEqual(TextStatistics.wordCount(text), 3)
        // 17 graphemes minus the attachment object.
        XCTAssertEqual(TextStatistics.characterCount(text), 17)
    }
}
