import XCTest
@testable import MDEditor

/// Format commands applied headless to a text storage, verified through the
/// serializer: format → serialize → expected Markdown, plus a round-trip
/// (parse → build → serialize) where the output must be a fixpoint.
final class FormatCommandTests: XCTestCase {
    /// parse → build → storage (unstyled; commands style as they go).
    private func makeStorage(_ markdown: String = "") -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        MarkdownSerializer.serialize(storage)
    }

    private func roundTrip(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    // MARK: - Bold / italic / strikethrough

    func testToggleBold() {
        let storage = makeStorage("hello world")
        FormatCommands.toggleBold(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello **world**\n")
        // The run must carry the bold trait, not literal markers in text.
        let font = storage.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello world\n")
    }

    func testToggleItalic() {
        let storage = makeStorage("hello world")
        FormatCommands.toggleItalic(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello *world*\n")
        FormatCommands.toggleItalic(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello world\n")
    }

    func testToggleStrikethrough() {
        let storage = makeStorage("hello world")
        FormatCommands.toggleStrikethrough(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello ~~world~~\n")
        FormatCommands.toggleStrikethrough(storage, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(serialize(storage), "hello world\n")
    }

    /// Mixed selection (part bold, part not): Word makes it all bold.
    func testToggleBoldOnMixedSelectionBoldsEverything() {
        let storage = makeStorage("plain **bold**")
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "**plain bold**\n")
        XCTAssertEqual(roundTrip("**plain bold**\n"), "**plain bold**\n")
    }

    // MARK: - Headings

    func testApplyHeadingAndBody() {
        let storage = makeStorage("Title")
        FormatCommands.applyHeading(level: 2, storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil) as? Int, 2)
        XCTAssertEqual(serialize(storage), "## Title\n")
        XCTAssertEqual(roundTrip("## Title\n"), "## Title\n")
        FormatCommands.applyBody(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertNil(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil))
        XCTAssertEqual(serialize(storage), "Title\n")
    }

    /// Heading styling is faux-bold; existing emphasis must be the only markers.
    func testHeadingKeepsEmphasisButAddsNone() {
        let storage = makeStorage("**Bold** title")
        FormatCommands.applyHeading(level: 1, storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(serialize(storage), "# **Bold** title\n")
    }

    func testHeadingOnlyAffectsSelectedParagraphs() {
        // Storage text: "One\nTwo".
        let storage = makeStorage("One\n\nTwo")
        FormatCommands.applyHeading(level: 3, storage: storage, selection: NSRange(location: 4, length: 3))
        XCTAssertEqual(serialize(storage), "One\n\n### Two\n")
    }

    // MARK: - Lists

    func testToggleBulletList() {
        // Storage text: "a\nb" (two paragraphs, one shared list object).
        let storage = makeStorage("a\n\nb")
        FormatCommands.toggleList(ordered: false, storage: storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "- a\n- b\n")
        XCTAssertEqual(roundTrip("- a\n- b\n"), "- a\n- b\n")
        FormatCommands.toggleList(ordered: false, storage: storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "a\n\nb\n")
    }

    func testToggleOrderedList() {
        let storage = makeStorage("a\n\nb")
        FormatCommands.toggleList(ordered: true, storage: storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "1. a\n2. b\n")
        XCTAssertEqual(roundTrip("1. a\n2. b\n"), "1. a\n2. b\n")
    }

    func testToggleListConvertsTypeAndBack() {
        let storage = makeStorage("- a")
        FormatCommands.toggleList(ordered: true, storage: storage, selection: NSRange(location: 0, length: 1))
        XCTAssertEqual(serialize(storage), "1. a\n")
        FormatCommands.toggleList(ordered: true, storage: storage, selection: NSRange(location: 0, length: 1))
        XCTAssertEqual(serialize(storage), "a\n")
    }

    // MARK: - Block quotes

    func testToggleBlockQuote() {
        let storage = makeStorage("quoted")
        FormatCommands.toggleBlockQuote(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(serialize(storage), "> quoted\n")
        XCTAssertEqual(roundTrip("> quoted\n"), "> quoted\n")
        FormatCommands.toggleBlockQuote(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(serialize(storage), "quoted\n")
    }

    func testToggleBlockQuoteMultipleParagraphs() {
        let storage = makeStorage("a\n\nb")
        FormatCommands.toggleBlockQuote(storage: storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "> a\n>\n> b\n")
        XCTAssertEqual(roundTrip("> a\n>\n> b\n"), "> a\n>\n> b\n")
    }

    // MARK: - Code blocks

    func testToggleCodeBlock() {
        let storage = makeStorage("let x = 1")
        FormatCommands.toggleCodeBlock(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(storage.attribute(MDAttr.codeBlock, at: 0, effectiveRange: nil) as? String, "")
        XCTAssertEqual(serialize(storage), "```\nlet x = 1\n```\n")
        XCTAssertEqual(roundTrip("```\nlet x = 1\n```\n"), "```\nlet x = 1\n```\n")
        FormatCommands.toggleCodeBlock(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(serialize(storage), "let x = 1\n")
    }

    // MARK: - Links

    func testInsertLinkOnSelection() {
        let storage = makeStorage("click here")
        let range = FormatCommands.insertLink(
            url: "https://example.com", title: nil,
            storage: storage, selection: NSRange(location: 6, length: 4)
        )
        XCTAssertEqual(serialize(storage), "click [here](https://example.com)\n")
        XCTAssertEqual(range, NSRange(location: 6, length: 4))
        XCTAssertEqual(roundTrip("click [here](https://example.com)\n"), "click [here](https://example.com)\n")
    }

    func testInsertLinkWithTitle() {
        let storage = makeStorage("text")
        FormatCommands.insertLink(
            url: "https://example.com", title: "Example",
            storage: storage, selection: NSRange(location: 0, length: 4)
        )
        XCTAssertEqual(serialize(storage), "[text](https://example.com \"Example\")\n")
    }

    func testInsertLinkAtInsertionPoint() {
        let storage = makeStorage()
        let range = FormatCommands.insertLink(
            url: "https://example.com", title: nil,
            storage: storage, selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(serialize(storage), "[link text](https://example.com)\n")
        XCTAssertEqual(range, NSRange(location: 0, length: 9))
    }

    // MARK: - Thematic break

    func testInsertThematicBreakAtDocumentEnd() {
        let storage = makeStorage("abc")
        let cursor = FormatCommands.insertThematicBreak(storage: storage, selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(serialize(storage), "abc\n\n---\n")
        XCTAssertEqual(cursor, storage.length, "cursor lands in the paragraph after the rule")
    }

    func testInsertThematicBreakBetweenParagraphs() {
        // Storage text: "abc\ndef".
        let storage = makeStorage("abc\n\ndef")
        let cursor = FormatCommands.insertThematicBreak(storage: storage, selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(serialize(storage), "abc\n\n---\n\ndef\n")
        XCTAssertEqual((storage.string as NSString).substring(with: NSRange(location: cursor, length: 3)), "def")
    }

    func testInsertThematicBreakInEmptyDocument() {
        let storage = makeStorage()
        FormatCommands.insertThematicBreak(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(serialize(storage), "---\n")
    }

    // MARK: - State inspection

    func testInspectReflectsSelection() {
        let storage = makeStorage("**bold**")
        var state = FormatCommands.inspect(storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertTrue(state.isBold)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: storage.length))
        state = FormatCommands.inspect(storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertFalse(state.isBold)
    }

    func testInspectHeadingLevel() {
        let storage = makeStorage("## Title")
        XCTAssertEqual(FormatCommands.inspect(storage, selection: NSRange(location: 0, length: 0)).headingLevel, 2)
    }
}
