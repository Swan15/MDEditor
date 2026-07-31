import XCTest
@testable import MDEditor

/// Editing behaviors driven headless against a text storage built via
/// parse → build, verified through semantic attributes and the serializer.
/// Where a behavior returns typing attributes, the tests "type" with them,
/// mirroring what the view layer does.
final class EditingBehaviorTests: XCTestCase {
    /// parse → build → storage (unstyled; behaviors style as they go).
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

    /// Collapsed-cursor context with an optional undo manager.
    private func context(
        _ storage: NSTextStorage, at location: Int, length: Int = 0,
        typingAttributes: [NSAttributedString.Key: Any] = [:],
        undoManager: UndoManager? = nil
    ) -> EditingBehavior.Context {
        EditingBehavior.Context(
            storage: storage,
            selection: NSRange(location: location, length: length),
            typingAttributes: typingAttributes,
            undoManager: undoManager
        )
    }

    /// Types text with the attributes a behavior returned (view-layer role).
    private func type(_ text: String, into storage: NSTextStorage, using result: EditingBehavior.Result) {
        storage.insert(NSAttributedString(string: text, attributes: result.typingAttributes ?? [:]), at: result.selection.location)
    }

    private func textLists(_ storage: NSTextStorage, at index: Int) -> [NSTextList] {
        (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    // MARK: - Return in lists

    func testReturnContinuesList() {
        // Storage text: "item".
        let storage = makeStorage("- item")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 4))
        XCTAssertEqual(result?.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(storage.string, "item\n")
        type("next", into: storage, using: result!)
        XCTAssertEqual(textLists(storage, at: 5).count, 1)
        XCTAssertEqual(serialize(storage), "- item\n- next\n")
        XCTAssertEqual(roundTrip("- item\n- next\n"), "- item\n- next\n")
    }

    func testReturnOnEmptyListItemExitsList() {
        // Parsed content never contains an empty item (cmark drops it), so
        // create one the way the user does: Return at the end of "a".
        let storage = makeStorage("- a\n- b")
        _ = EditingBehavior.insertNewline(in: context(storage, at: 1))
        XCTAssertEqual(textLists(storage, at: 2).count, 1)
        // Return on the empty item exits the list (Word behavior).
        let result = EditingBehavior.insertNewline(in: context(storage, at: 2))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertTrue(textLists(storage, at: 2).isEmpty)
        XCTAssertNil(storage.attribute(MDAttr.listItemStart, at: 2, effectiveRange: nil))
        // Both items survive a round trip; the exited paragraph is plain.
        XCTAssertEqual(roundTrip(serialize(storage)), "- a\n- b\n")
    }

    func testReturnOnTrailingEmptyListItemExitsViaTypingAttributes() {
        // Storage text: "a".
        let storage = makeStorage("- a")
        let first = EditingBehavior.insertNewline(in: context(storage, at: 1))
        XCTAssertEqual(first?.selection, NSRange(location: 2, length: 0))
        // The fresh item has no characters yet; the typing attributes carry
        // the list. A second Return exits instead of adding another item.
        let second = EditingBehavior.insertNewline(in: context(
            storage, at: 2, typingAttributes: first?.typingAttributes ?? [:]
        ))
        XCTAssertEqual(second?.mutated, false)
        type("b", into: storage, using: second!)
        XCTAssertEqual(serialize(storage), "- a\n\nb\n")
    }

    func testReturnInTaskListStartsUncheckedItem() {
        // Storage text: "done".
        let storage = makeStorage("- [x] done")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 4))
        type("new", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "- [x] done\n- [ ] new\n")
    }

    // MARK: - Return in headings

    func testReturnAtEndOfHeadingStartsBody() {
        // Storage text: "Title".
        let storage = makeStorage("# Title")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 5))
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
        type("Body", into: storage, using: result!)
        XCTAssertNil(storage.attribute(MDAttr.headingLevel, at: 6, effectiveRange: nil))
        XCTAssertEqual(serialize(storage), "# Title\n\nBody\n")
    }

    func testReturnAtEndOfHeadingMidDocumentStartsBody() {
        // Storage text: "One\nTwo" (heading + body).
        let storage = makeStorage("# One\n\nTwo")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 3))
        type("New", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "# One\n\nNew\n\nTwo\n")
        // The following paragraph keeps its own (unstyled) identity.
        XCTAssertNil(storage.attribute(MDAttr.headingLevel, at: 8, effectiveRange: nil))
    }

    func testReturnInMiddleOfHeadingSplitsIntoTwoHeadings() {
        // Storage text: "Title".
        let storage = makeStorage("# Title")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 2))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 3, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(serialize(storage), "# Ti\n\n# tle\n")
        XCTAssertEqual(roundTrip("# Ti\n\n# tle\n"), "# Ti\n\n# tle\n")
    }

    // MARK: - Return in block quotes

    func testReturnContinuesBlockQuote() {
        // Storage text: "quoted".
        let storage = makeStorage("> quoted")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 6))
        type("more", into: storage, using: result!)
        XCTAssertEqual(storage.attribute(MDAttr.blockQuoteDepth, at: 7, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(serialize(storage), "> quoted\n>\n> more\n")
        XCTAssertEqual(roundTrip("> quoted\n>\n> more\n"), "> quoted\n>\n> more\n")
    }

    func testReturnOnEmptyQuotedParagraphExitsToBody() {
        // "> a\n>\n> b" parses to two quoted paragraphs (the ">" line is just
        // the separator); create an empty quoted paragraph the way the user
        // does: Return at the end of "a".
        let storage = makeStorage("> a\n>\n> b")
        _ = EditingBehavior.insertNewline(in: context(storage, at: 1))
        // Return on the empty quoted paragraph exits to body.
        let result = EditingBehavior.insertNewline(in: context(storage, at: 2))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertNil(storage.attribute(MDAttr.blockQuoteDepth, at: 2, effectiveRange: nil))
        // Both quoted halves survive a round trip.
        XCTAssertEqual(roundTrip(serialize(storage)), "> a\n>\n> b\n")
    }

    // MARK: - Return in code blocks

    func testReturnInCodeBlockStaysInCode() {
        // Storage text: "let x = 1".
        let storage = makeStorage("```\nlet x = 1\n```")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 4))
        XCTAssertEqual(result?.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(storage.string, "let \u{2028}x = 1")
        XCTAssertEqual(serialize(storage), "```\nlet \nx = 1\n```\n")
        XCTAssertEqual(roundTrip("```\nlet \nx = 1\n```\n"), "```\nlet \nx = 1\n```\n")
    }

    func testReturnOnEmptyLastLineOfCodeBlockExitsToBody() {
        // Storage text: "code\u{2028}" (code block with an empty last line).
        let storage = makeStorage("```\ncode\n\n```")
        XCTAssertEqual(storage.string, "code\u{2028}")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 5))
        XCTAssertEqual(result?.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(serialize(storage), "```\ncode\n```\n")
        type("body", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "```\ncode\n```\n\nbody\n")
    }

    func testReturnOnEmptyCodeParagraphConvertsToBody() {
        // Storage text: "before\n\nafter" with an empty code paragraph between.
        let storage = makeStorage("before\n\n```\n```\n\nafter")
        XCTAssertEqual(storage.attribute(MDAttr.codeBlock, at: 7, effectiveRange: nil) as? String, "")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 7))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertNil(storage.attribute(MDAttr.codeBlock, at: 7, effectiveRange: nil))
        XCTAssertEqual(roundTrip(serialize(storage)), "before\n\nafter\n")
    }

    // MARK: - Return elsewhere

    func testReturnOnThematicBreakStartsBodyBelow() {
        // Storage text: "\u{00A0}" (rule placeholder).
        let storage = makeStorage("---")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 0))
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(serialize(storage), "---\n")
        type("x", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "---\n\nx\n")
    }

    func testReturnInTableCellInsertsLineSeparator() {
        // Storage text: cells "a", "b", "c", "d".
        let storage = makeStorage("| a | b |\n| --- | --- |\n| c | d |")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 1))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertTrue(storage.string.hasPrefix("a\u{2028}"))
        // The table structure survives (delimiter row intact).
        XCTAssertTrue(serialize(storage).contains("| --- | --- |"))
    }

    func testReturnInPlainBodyFallsThroughToDefault() {
        let storage = makeStorage("plain")
        XCTAssertNil(EditingBehavior.insertNewline(in: context(storage, at: 3)))
    }

    func testReturnReplacingSelectionInBodyDeletesAndBreaks() {
        // Storage text: "hello world".
        let storage = makeStorage("hello world")
        let result = EditingBehavior.insertNewline(in: context(storage, at: 5, length: 6))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(storage.string, "hello\n")
        XCTAssertEqual(serialize(storage), "hello\n")
    }

    // MARK: - Tab / Shift-Tab

    func testTabIndentsListItemOneLevel() {
        // Storage text: "a".
        let storage = makeStorage("- a")
        let result = EditingBehavior.indent(in: context(storage, at: 1))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(textLists(storage, at: 0).count, 2)
        XCTAssertEqual(serialize(storage), "  - a\n")
    }

    func testTabIndentsOrderedListKeepingType() {
        let storage = makeStorage("1. a")
        _ = EditingBehavior.indent(in: context(storage, at: 1))
        // Nested content indents by the parent marker's width ("1. " = 3).
        XCTAssertEqual(serialize(storage), "   1. a\n")
    }

    func testShiftTabOutdentsAndFinallyRemovesFromList() {
        let storage = makeStorage("- a")
        _ = EditingBehavior.indent(in: context(storage, at: 1))
        XCTAssertEqual(textLists(storage, at: 0).count, 2)
        var result = EditingBehavior.outdent(in: context(storage, at: 1))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(serialize(storage), "- a\n")
        result = EditingBehavior.outdent(in: context(storage, at: 1))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertTrue(textLists(storage, at: 0).isEmpty)
        XCTAssertNil(storage.attribute(MDAttr.listItemStart, at: 0, effectiveRange: nil))
        XCTAssertEqual(serialize(storage), "a\n")
        // Past depth 0 there is nothing to outdent: default handling.
        XCTAssertNil(EditingBehavior.outdent(in: context(storage, at: 1)))
    }

    func testTabInCodeBlockInsertsLiteralTab() {
        // Storage text: "x".
        let storage = makeStorage("```\nx\n```")
        let result = EditingBehavior.indent(in: context(storage, at: 0))
        XCTAssertEqual(result?.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(serialize(storage), "```\n\tx\n```\n")
    }

    func testTabInBodyIsSwallowed() {
        // A literal tab at line start would reparse as an indented code
        // block, so body Tab inserts nothing.
        let storage = makeStorage("plain")
        let result = EditingBehavior.indent(in: context(storage, at: 2))
        XCTAssertEqual(result?.mutated, false)
        XCTAssertEqual(serialize(storage), "plain\n")
    }

    // MARK: - Backspace

    func testBackspaceAtStartOfHeadingClearsStyleThenDefaults() {
        // Storage text: "Title".
        let storage = makeStorage("# Title")
        let result = EditingBehavior.deleteBackward(in: context(storage, at: 0))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 0))
        XCTAssertNil(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, "Title")
        XCTAssertEqual(serialize(storage), "Title\n")
        // Second press: unstyled paragraph → default merge/delete behavior.
        XCTAssertNil(EditingBehavior.deleteBackward(in: context(storage, at: 0)))
    }

    func testBackspaceAtStartOfListItemClearsStyle() {
        // Storage text: "item".
        let storage = makeStorage("- item")
        let result = EditingBehavior.deleteBackward(in: context(storage, at: 0))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertTrue(textLists(storage, at: 0).isEmpty)
        XCTAssertEqual(serialize(storage), "item\n")
    }

    func testBackspaceAtStartOfQuoteClearsStyle() {
        let storage = makeStorage("> quoted")
        let result = EditingBehavior.deleteBackward(in: context(storage, at: 0))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertNil(storage.attribute(MDAttr.blockQuoteDepth, at: 0, effectiveRange: nil))
        XCTAssertEqual(serialize(storage), "quoted\n")
    }

    func testBackspaceAtStartOfCodeBlockClearsStyle() {
        // Storage text: "a\u{2028}b" — line separators survive as hard breaks.
        let storage = makeStorage("```\na\nb\n```")
        let result = EditingBehavior.deleteBackward(in: context(storage, at: 0))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertNil(storage.attribute(MDAttr.codeBlock, at: 0, effectiveRange: nil))
        XCTAssertEqual(serialize(storage), "a\\\nb\n")
    }

    func testBackspaceMidParagraphIsDefault() {
        let storage = makeStorage("# Title")
        XCTAssertNil(EditingBehavior.deleteBackward(in: context(storage, at: 3)))
    }

    func testBackspaceAfterRuleDeletesRule() {
        // Storage text: "text\n\u{00A0}\nmore" (rule paragraph in the middle).
        let storage = makeStorage("text\n\n---\n\nmore")
        let result = EditingBehavior.deleteBackward(in: context(storage, at: 7))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(serialize(storage), "text\n\nmore\n")
    }

    // MARK: - Undo

    func testUndoRestoresClearedStyle() {
        let undoManager = UndoManager()
        let storage = makeStorage("# Title")
        _ = EditingBehavior.deleteBackward(in: context(storage, at: 0, undoManager: undoManager))
        XCTAssertEqual(serialize(storage), "Title\n")
        undoManager.undo()
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(serialize(storage), "# Title\n")
        undoManager.redo()
        XCTAssertEqual(serialize(storage), "Title\n")
    }

    func testUndoRestoresListSplit() {
        let undoManager = UndoManager()
        let storage = makeStorage("- item")
        _ = EditingBehavior.insertNewline(in: context(storage, at: 4, undoManager: undoManager))
        XCTAssertEqual(storage.string, "item\n")
        undoManager.undo()
        XCTAssertEqual(serialize(storage), "- item\n")
        undoManager.redo()
        XCTAssertEqual(storage.string, "item\n")
    }

    func testUndoRestoresIndent() {
        let undoManager = UndoManager()
        let storage = makeStorage("- a")
        _ = EditingBehavior.indent(in: context(storage, at: 1, undoManager: undoManager))
        XCTAssertEqual(textLists(storage, at: 0).count, 2)
        undoManager.undo()
        XCTAssertEqual(textLists(storage, at: 0).count, 1)
        XCTAssertEqual(serialize(storage), "- a\n")
    }
}
