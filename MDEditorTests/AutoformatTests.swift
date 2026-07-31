import XCTest
@testable import MDEditor

/// Autoformat-as-you-type: trigger paragraphs + Space convert headless,
/// verified through semantic attributes and the serializer (parse-equivalence
/// keeps the output canonical). Where a transform returns typing attributes,
/// the tests "type" with them, mirroring the view layer.
final class AutoformatTests: XCTestCase {
    /// parse → build → storage (unstyled; the transform styles as it goes).
    private func makeStorage(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    /// Storage holding exactly `text` in a plain body paragraph.
    private func bodyStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.append(NSAttributedString(string: text, attributes: [
            .font: StyleEngine.bodyFont,
            .foregroundColor: NSColor.labelColor
        ]))
        return storage
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        MarkdownSerializer.serialize(storage)
    }

    private func roundTrip(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    /// Runs the transform for a typed Space (or another character).
    private func transform(
        _ storage: NSTextStorage, at location: Int? = nil,
        typed: String = " ", enabled: Bool = true,
        undoManager: UndoManager? = nil
    ) -> EditingBehavior.Result? {
        Autoformat.transform(
            typedCharacter: typed,
            enabled: enabled,
            in: EditingBehavior.Context(
                storage: storage,
                selection: NSRange(location: location ?? storage.length, length: 0),
                undoManager: undoManager
            )
        )
    }

    /// Types text with the attributes a transform returned (view-layer role).
    private func type(_ text: String, into storage: NSTextStorage, using result: EditingBehavior.Result) {
        storage.insert(NSAttributedString(string: text, attributes: result.typingAttributes ?? [:]), at: result.selection.location)
    }

    private func textLists(_ storage: NSTextStorage, at index: Int) -> [NSTextList] {
        (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    // MARK: - Headings

    func testHeadingLevels() {
        for level in 1...6 {
            let storage = bodyStorage(String(repeating: "#", count: level))
            let result = transform(storage)
            XCTAssertEqual(result?.selection, NSRange(location: 0, length: 0), "level \(level)")
            XCTAssertEqual(result?.mutated, true)
            XCTAssertEqual(storage.string, "", "trigger characters are consumed, level \(level)")
            XCTAssertEqual(result?.typingAttributes?[MDAttr.headingLevel] as? Int, level)
            type("Title", into: storage, using: result!)
            let expected = String(repeating: "#", count: level) + " Title\n"
            XCTAssertEqual(serialize(storage), expected, "level \(level)")
            XCTAssertEqual(roundTrip(serialize(storage)), expected, "canonical, level \(level)")
        }
    }

    /// Seven hashes is not a heading trigger.
    func testSevenHashesIsNoTrigger() {
        let storage = bodyStorage("#######")
        XCTAssertNil(transform(storage))
    }

    /// A trigger paragraph with a trailing newline keeps the attribute on
    /// the (empty) paragraph itself, so the conversion survives even if the
    /// user clicks away before typing.
    func testHeadingMidDocument() {
        // Storage text: "Intro\n#\nOutro" (three body paragraphs).
        let storage = bodyStorage("Intro\n#\nOutro")
        let result = transform(storage, at: 7)
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 6, effectiveRange: nil) as? Int, 1)
        type("T", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "Intro\n\n# T\n\nOutro\n")
    }

    // MARK: - Lists

    func testBulletList() {
        for marker in ["-", "*"] {
            let storage = bodyStorage(marker)
            let result = transform(storage)
            XCTAssertEqual(result?.mutated, true, "marker \(marker)")
            XCTAssertEqual(result?.typingAttributes?[MDAttr.listItemStart] as? Bool, true)
            type("item", into: storage, using: result!)
            XCTAssertEqual(textLists(storage, at: 0).last?.markerFormat, .disc)
            XCTAssertEqual(serialize(storage), "- item\n")
            XCTAssertEqual(roundTrip("- item\n"), "- item\n")
        }
    }

    func testOrderedList() {
        let storage = bodyStorage("1.")
        let result = transform(storage)
        type("item", into: storage, using: result!)
        XCTAssertEqual(textLists(storage, at: 0).last?.markerFormat, .decimal)
        XCTAssertEqual(serialize(storage), "1. item\n")
    }

    /// The typed number becomes the list's start number.
    func testOrderedListStartNumber() {
        let storage = bodyStorage("3.")
        let result = transform(storage)
        type("third", into: storage, using: result!)
        XCTAssertEqual(textLists(storage, at: 0).last?.startingItemNumber, 3)
        XCTAssertEqual(serialize(storage), "3. third\n")
        XCTAssertEqual(roundTrip("3. third\n"), "3. third\n")
    }

    // MARK: - Block quote

    func testBlockQuote() {
        let storage = bodyStorage(">")
        let result = transform(storage)
        XCTAssertEqual(result?.typingAttributes?[MDAttr.blockQuoteDepth] as? Int, 1)
        type("quoted", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "> quoted\n")
        XCTAssertEqual(roundTrip("> quoted\n"), "> quoted\n")
    }

    // MARK: - Code block

    func testCodeBlock() {
        let storage = bodyStorage("```")
        let result = transform(storage)
        XCTAssertEqual(result?.typingAttributes?[MDAttr.codeBlock] as? String, "")
        type("let x = 1", into: storage, using: result!)
        XCTAssertEqual(storage.attribute(MDAttr.codeBlock, at: 0, effectiveRange: nil) as? String, "")
        XCTAssertEqual(serialize(storage), "```\nlet x = 1\n```\n")
        XCTAssertEqual(roundTrip("```\nlet x = 1\n```\n"), "```\nlet x = 1\n```\n")
    }

    // MARK: - Thematic break

    func testThematicBreak() {
        let storage = bodyStorage("---")
        let result = transform(storage)
        // The rule replaced the paragraph; the caret landed below it.
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
        XCTAssertTrue(storage.attribute(.attachment, at: 0, effectiveRange: nil) is MDRuleAttachment)
        XCTAssertEqual(serialize(storage), "---\n")
        // Typing continues in body text below the rule.
        type("after", into: storage, using: result!)
        XCTAssertEqual(serialize(storage), "---\n\nafter\n")
    }

    /// Smart-dash substitution turns a typed `---` into `—-` (em + hyphen);
    /// that must still trigger the rule.
    func testThematicBreakAfterSmartDashSubstitution() {
        for variant in ["—-", "—–", "-—"] {
            let storage = bodyStorage(variant)
            XCTAssertNotNil(transform(storage), "variant \(variant)")
            XCTAssertEqual(serialize(storage), "---\n", "variant \(variant)")
        }
    }

    /// Two hyphens are not a rule.
    func testTwoHyphensIsNoTrigger() {
        let storage = bodyStorage("--")
        XCTAssertNil(transform(storage))
    }

    /// A rule replacing a middle paragraph leaves the neighbors intact.
    func testThematicBreakMidDocument() {
        // Storage text: "Intro\n---\nOutro" (three body paragraphs).
        let storage = bodyStorage("Intro\n---\nOutro")
        let result = transform(storage, at: 9)
        XCTAssertEqual(result?.selection, NSRange(location: 8, length: 0))
        XCTAssertEqual(serialize(storage), "Intro\n\n---\n\nOutro\n")
        XCTAssertEqual(roundTrip(serialize(storage)), "Intro\n\n---\n\nOutro\n")
    }

    // MARK: - Negative cases

    /// The trigger must be the paragraph's whole content.
    func testNoTriggerWithOtherTextAround() {
        for text in ["a#", "#a", "a>", "-a", "1.x", "``", "````x"] {
            XCTAssertNil(transform(bodyStorage(text)), "text \(text)")
        }
    }

    /// The caret must be at the end of the trigger.
    func testNoTriggerWhenCaretInsideTrigger() {
        let storage = bodyStorage("##")
        XCTAssertNil(transform(storage, at: 1))
    }

    /// Only Space completes a trigger.
    func testNoTransformForOtherTypedCharacters() {
        for typed in ["x", "\n", "\t", "."] {
            XCTAssertNil(transform(bodyStorage("#"), typed: typed), "typed \(typed)")
        }
    }

    /// A non-collapsed selection never transforms.
    func testNoTransformWithSelection() {
        let storage = bodyStorage("#")
        let result = Autoformat.transform(
            typedCharacter: " ",
            enabled: true,
            in: EditingBehavior.Context(storage: storage, selection: NSRange(location: 0, length: 1))
        )
        XCTAssertNil(result)
    }

    /// The preference gates everything.
    func testDisabledPreferenceReturnsNil() {
        for trigger in ["#", "-", "*", "1.", ">", "```", "---"] {
            XCTAssertNil(transform(bodyStorage(trigger), enabled: false), "trigger \(trigger)")
        }
    }

    /// No transform inside styled contexts.
    func testNoTriggerInStyledContexts() {
        // Heading whose content is the trigger.
        XCTAssertNil(transform(makeStorage("# #")))
        // Code block whose content is the trigger.
        XCTAssertNil(transform(makeStorage("```\n#\n```")))
        // Table cell whose content is the trigger.
        let table = makeStorage("| # |\n| --- |\n| b |")
        let hash = (table.string as NSString).range(of: "#").location
        XCTAssertNil(transform(table, at: hash + 1))
        // Block quote, list item and raw block carrying trigger text.
        let quoted = bodyStorage(">")
        quoted.addAttribute(MDAttr.blockQuoteDepth, value: 1, range: NSRange(location: 0, length: 1))
        XCTAssertNil(transform(quoted))
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        let listed = bodyStorage("-")
        listed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 1))
        XCTAssertNil(transform(listed))
        let raw = bodyStorage("#")
        raw.addAttribute(MDAttr.rawBlock, value: "#", range: NSRange(location: 0, length: 1))
        XCTAssertNil(transform(raw))
    }

    /// Storage must not change when nothing triggers.
    func testFailedTransformLeavesStorageUntouched() {
        let storage = makeStorage("# Title\n\nBody")
        let before = storage.string
        XCTAssertNil(transform(storage, at: 5))
        XCTAssertEqual(storage.string, before)
    }

    // MARK: - Undo

    func testUndoRestoresTriggerText() {
        let undoManager = UndoManager()
        let storage = bodyStorage("#")
        _ = transform(storage, undoManager: undoManager)
        XCTAssertEqual(storage.string, "")
        undoManager.undo()
        XCTAssertEqual(storage.string, "#")
        undoManager.redo()
        XCTAssertEqual(storage.string, "")
    }

    func testUndoRestoresDashesBeforeRule() {
        let undoManager = UndoManager()
        let storage = bodyStorage("---")
        _ = transform(storage, undoManager: undoManager)
        XCTAssertEqual(serialize(storage), "---\n")
        undoManager.undo()
        XCTAssertEqual(storage.string, "---")
        undoManager.redo()
        XCTAssertEqual(serialize(storage), "---\n")
    }
}
