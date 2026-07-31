import XCTest
@testable import MDEditor

/// Targeted tests for the tricky corners of `MarkdownSerializer`:
/// emphasis boundaries, escaping, list numbering, quotes, tables, raw blocks.
final class SerializerTests: XCTestCase {
    /// parse → build → serialize.
    private func serialize(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    /// Serializing must reproduce canonical input exactly, and re-running on
    /// the output must be stable (used for non-canonical inputs too).
    private func assertCanonical(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(serialize(source), source, file: file, line: line)
    }

    private func assertCanonicalizes(_ input: String, to expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(serialize(input), expected, file: file, line: line)
        XCTAssertEqual(serialize(expected), expected, "output not a fixpoint", file: file, line: line)
    }

    /// Builds a text run with inline attributes the way the builder would.
    private func run(
        _ text: String,
        bold: Bool = false,
        italic: Bool = false,
        strike: Bool = false,
        code: Bool = false,
        link: String? = nil
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: MDFont.make(bold: bold, italic: italic)]
        if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if code { attributes[MDAttr.inlineCode] = true }
        if let link { attributes[.link] = URL(string: link) ?? (link as NSString) }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func serializeRuns(_ runs: [NSAttributedString]) -> String {
        let string = NSMutableAttributedString()
        for run in runs { string.append(run) }
        return MarkdownSerializer.serialize(string)
    }

    // MARK: - Emphasis boundary disambiguation

    func testBoldItalicCombinedRun() {
        XCTAssertEqual(serializeRuns([run("x", bold: true, italic: true)]), "***x***\n")
    }

    func testBoldThenItalicBoundary() {
        // Naive `**a**` + `*b*` would merge into one delimiter run and misparse.
        let output = serializeRuns([run("a", bold: true), run("b", italic: true)])
        XCTAssertEqual(output, "**a***b*\n")
        assertCanonical(output)
    }

    func testItalicThenBoldBoundary() {
        let output = serializeRuns([run("a", italic: true), run("b", bold: true)])
        XCTAssertEqual(output, "*a***b**\n")
        assertCanonical(output)
    }

    func testSharedMarkerStaysOpenAcrossBoundary() {
        // `**a***b***` misparses; the shared strong marker must stay open.
        let output = serializeRuns([run("a", bold: true), run("b", bold: true, italic: true)])
        XCTAssertEqual(output, "**a*b***\n")
        assertCanonical(output)
    }

    func testClosingOnlyInnerMarker() {
        let output = serializeRuns([run("a", bold: true, italic: true), run("b", bold: true)])
        XCTAssertEqual(output, "***a*b**\n")
        assertCanonical(output)
    }

    func testStrikethroughWrapsBold() {
        let output = serializeRuns([run("a", strike: true), run("b", bold: true, strike: true)])
        XCTAssertEqual(output, "~~a**b**~~\n")
        assertCanonical(output)
    }

    func testNestedEmphasisSourceCanonicalizes() {
        assertCanonical("**Bold with *italic* inside.**\n")
    }

    // MARK: - Escaping

    func testEscapesLiteralMarkupCharacters() {
        assertCanonical("\\*not emphasis\\* and \\[not a link\\]\n")
    }

    func testUnderscoreEscapedInPlainText() {
        assertCanonicalizes("a_b_c\n", to: "a\\_b\\_c\n")
    }

    func testBackslashEscaped() {
        assertCanonicalizes("a\\\\b\n", to: "a\\\\b\n")
    }

    func testTildeRunsEscapedInPlainText() {
        assertCanonical("\\~\\~not strike\\~\\~\n")
    }

    func testEntityLookingTextEscaped() {
        assertCanonicalizes("\\&copy;\n", to: "&amp;copy;\n")
    }

    func testRealEntityCharacterNotEscaped() {
        assertCanonical("Copyright © here.\n")
    }

    func testTagLookingTextEscaped() {
        assertCanonical("\\<div> is not HTML here.\n")
    }

    func testParagraphLeadingMarkersEscaped() {
        assertCanonical("\\# not a heading\n")
        assertCanonical("\\- not a list\n")
        assertCanonical("\\+ also not a list\n")
        assertCanonical("\\> not a quote\n")
        assertCanonical("1\\. not an item\n")
        assertCanonical("\\---\n")
    }

    func testExclamationBeforeLinkEscaped() {
        assertCanonical("\\![x](https://example.com)\n")
    }

    // MARK: - Links and code spans

    func testAutolinkCanonicalizes() {
        assertCanonicalizes(
            "<https://example.com>\n",
            to: "[https://example.com](https://example.com)\n"
        )
    }

    func testCodeSpanWithBacktickUsesLongerFence() {
        assertCanonical("``back`tick``\n")
    }

    func testCodeSpanContentNotEscaped() {
        assertCanonical("`*not emphasis* & <raw>`\n")
    }

    // MARK: - Lists

    func testOrderedListNumberingRestartsAcrossLists() {
        assertCanonical("1. a\n2. b\n\n- x\n\n1. c\n2. d\n")
    }

    func testOrderedListStartIndexPreserved() {
        assertCanonical("3. a\n4. b\n")
    }

    func testNestedOrderedListNumbering() {
        assertCanonical("1. a\n   1. x\n   2. y\n2. b\n")
    }

    func testNestedListNumberingRestartsPerParentItem() {
        assertCanonical("1. a\n   1. x\n2. b\n   1. y\n")
    }

    func testDeeplyNestedMixedLists() {
        assertCanonical("1. a\n   - x\n     1. deep\n   - y\n2. b\n")
    }

    func testMultiParagraphListItem() {
        assertCanonical("- a\n\n  continued\n- b\n")
    }

    func testTaskList() {
        assertCanonical("- [ ] open\n- [x] done\n")
    }

    // MARK: - Block quotes

    func testQuoteWithListCombination() {
        assertCanonical("> Quoted:\n>\n> - a\n> - b\n>\n> End.\n")
    }

    func testNestedQuotes() {
        assertCanonical("> outer\n>\n> > inner\n>\n> back\n")
    }

    func testQuoteWithHeadingAndRule() {
        assertCanonical("> # Title\n>\n> ---\n>\n> after\n")
    }

    // MARK: - Tables

    func testRaggedTableRowIsPadded() {
        assertCanonicalizes(
            "| a | b | c |\n| --- | --- | --- |\n| 1 |\n",
            to: "| a | b | c |\n| --- | --- | --- |\n| 1 |  |  |\n"
        )
    }

    func testTableAlignmentsPreserved() {
        assertCanonical("| l | c | r |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |\n")
    }

    func testTablePipeInCellEscaped() {
        assertCanonical("| a \\| b |\n| --- |\n| c |\n")
    }

    // MARK: - Raw blocks

    func testHTMLBlockPreservedVerbatim() {
        assertCanonical("<div   class=\"x\"\n    id=\"y\">\ncontent with **not bold** and [not a link](a)\n</div>\n")
    }

    func testInlineHTMLMakesWholeParagraphRaw() {
        assertCanonical("Before <span   class=\"odd\">inline</span> after.\n")
    }

    func testHTMLCommentBlockPreserved() {
        assertCanonical("Text.\n\n<!-- comment with *markup* -->\n\nMore.\n")
    }

    // MARK: - Hand-built strings

    func testImageAttachmentSerialization() {
        let attachment = MDImageAttachment(source: "pic.png", altText: "A [pic]", title: "Title")
        let string = NSAttributedString(attachment: attachment)
        XCTAssertEqual(MarkdownSerializer.serialize(string), "![A \\[pic\\]](pic.png \"Title\")\n")
    }

    func testLinkWithTitleRun() {
        let string = NSMutableAttributedString()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MDFont.make(),
            .link: URL(string: "https://example.com")!,
            MDAttr.linkTitle: "Example",
        ]
        string.append(NSAttributedString(string: "text", attributes: attributes))
        attributes = [.font: MDFont.make()]
        string.append(NSAttributedString(string: " after", attributes: attributes))
        XCTAssertEqual(MarkdownSerializer.serialize(string), "[text](https://example.com \"Example\") after\n")
    }

    func testHeadingAttributeSerialization() {
        let string = NSMutableAttributedString(string: "Title")
        string.addAttribute(MDAttr.headingLevel, value: 2, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(MarkdownSerializer.serialize(string), "## Title\n")
    }

    func testEmptyStringSerializesEmpty() {
        XCTAssertEqual(MarkdownSerializer.serialize(NSAttributedString()), "")
    }
}
