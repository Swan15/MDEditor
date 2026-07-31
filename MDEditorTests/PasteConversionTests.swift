import XCTest
@testable import MDEditor

/// Plain-text paste conversion: the Markdown-detection heuristics and the
/// styled insertion, verified through the serializer.
final class PasteConversionTests: XCTestCase {
    private func makeStorage(_ markdown: String = "") -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        MarkdownSerializer.serialize(storage)
    }

    // MARK: - Detection: converts

    func testDetectsMarkdownConstructs() {
        let markdown = [
            "# Heading",
            "## H2",
            "- item\n- other",
            "1. first\n2. second",
            "* bullet",
            "> quoted text",
            "```\ncode\n```",
            "~~~\ncode\n~~~",
            "---",
            "* * *",
            "| --- | --- |",
            "| --- |:---:|",
            "some **bold** text",
            "some __bold__ text",
            "some *italic* text",
            "some _italic_ text",
            "some ~~struck~~ text",
            "a [link](https://example.com)",
            "an ![image](pic.png)",
            "some `code` span",
        ]
        for text in markdown {
            XCTAssertTrue(PasteConversion.shouldConvertPlainText(text), "should convert: \(text)")
        }
    }

    // MARK: - Detection: stays plain

    func testPlainProseIsNotConverted() {
        let prose = [
            "hello world",
            "",
            "2 * 3 * 4",
            "snake_case_name",
            "C# is great",
            "1.5 liters of water",
            "https://example.com/page",
            "a > b comparison",
            "not a ` half code",
            "call f(x) then g(y)",
            "#hashtag",
        ]
        for text in prose {
            XCTAssertFalse(PasteConversion.shouldConvertPlainText(text), "should stay plain: \(text)")
        }
    }

    // MARK: - Insertion

    func testInsertAtParagraphEndSplitsFirst() {
        // Storage text: "body text".
        let storage = makeStorage("body text")
        let cursor = PasteConversion.insert(
            markdown: "# Hi", storage: storage, selection: NSRange(location: 9, length: 0)
        )
        XCTAssertEqual(cursor, storage.length)
        XCTAssertEqual(serialize(storage), "body text\n\n# Hi\n")
    }

    func testInsertAtStartOfParagraphPushesItDown() {
        // Storage text: "x".
        let storage = makeStorage("x")
        let cursor = PasteConversion.insert(
            markdown: "# Hi", storage: storage, selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(cursor, 2)
        XCTAssertEqual(serialize(storage), "# Hi\n\nx\n")
    }

    func testInsertIntoEmptyDocument() {
        let storage = makeStorage()
        PasteConversion.insert(
            markdown: "- a\n- b", storage: storage, selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(serialize(storage), "- a\n- b\n")
    }

    func testInsertReplacesSelection() {
        // Storage text: "abcdef".
        let storage = makeStorage("abcdef")
        PasteConversion.insert(
            markdown: "**bold**", storage: storage, selection: NSRange(location: 2, length: 2)
        )
        XCTAssertEqual(serialize(storage), "ab\n\n**bold**ef\n")
    }

    func testInsertedListKeepsSemantics() {
        let storage = makeStorage()
        PasteConversion.insert(
            markdown: "- [x] done\n- [ ] todo", storage: storage, selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(storage.attribute(MDAttr.checkbox, at: 0, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(serialize(storage), "- [x] done\n- [ ] todo\n")
    }
}
