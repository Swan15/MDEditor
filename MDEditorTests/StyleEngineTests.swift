import XCTest
@testable import MDEditor

/// Visual styling derived from semantic attributes: fonts, colors, indents —
/// and the guarantee that styling never rewrites semantics or loses traits.
final class StyleEngineTests: XCTestCase {
    /// parse → build → install into a storage → full style pass.
    private func styledStorage(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        return storage
    }

    private func font(
        _ storage: NSTextStorage, at index: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> NSFont {
        guard let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else {
            XCTFail("no font at \(index)", file: file, line: line)
            return NSFont.systemFont(ofSize: 0)
        }
        return font
    }

    // MARK: - Body and headings

    func testBodyFont() {
        let storage = styledStorage("Hello world")
        XCTAssertEqual(font(storage, at: 0).pointSize, StyleEngine.bodySize)
    }

    func testHeadingIsLargerButNotTraitBold() {
        let storage = styledStorage("# Title")
        let heading = font(storage, at: 0)
        XCTAssertGreaterThan(heading.pointSize, StyleEngine.bodySize)
        // Faux bold only: a bold *trait* would serialize as `**Title**`.
        XCTAssertFalse(heading.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(storage.attribute(MDAttr.headingLevel, at: 0, effectiveRange: nil) as? Int, 1)
    }

    func testHeadingSizesDescend() {
        // Storage text: "One\nTwo\nThree" (paragraph separators at 3 and 7).
        let storage = styledStorage("# One\n\n## Two\n\n### Three")
        let h1 = font(storage, at: 0).pointSize
        let h2 = font(storage, at: 4).pointSize
        let h3 = font(storage, at: 8).pointSize
        XCTAssertGreaterThan(h1, h2)
        XCTAssertGreaterThan(h2, h3)
    }

    /// Re-styling a heading must preserve a bold run inside it.
    func testBoldTraitSurvivesRestylingAHeading() {
        // Storage text: "Bold plain".
        let storage = styledStorage("# **Bold** plain")
        let boldFont = font(storage, at: 2)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(boldFont.pointSize, StyleEngine.headingSizes[0])
        let plainFont = font(storage, at: 7)
        XCTAssertFalse(plainFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(plainFont.pointSize, StyleEngine.headingSizes[0])
    }

    // MARK: - Block quotes

    func testBlockQuoteIndentAndColor() {
        let storage = styledStorage("> Quoted")
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )
        XCTAssertEqual(storage.attribute(MDAttr.blockQuoteDepth, at: 0, effectiveRange: nil) as? Int, 1)
    }

    func testNestedQuoteIndentScalesWithDepth() {
        // Storage text: "One\nTwo".
        let storage = styledStorage("> One\n>\n>> Two")
        let outer = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let inner = storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(storage.attribute(MDAttr.blockQuoteDepth, at: 4, effectiveRange: nil) as? Int, 2)
        XCTAssertGreaterThan(inner?.headIndent ?? 0, outer?.headIndent ?? 0)
    }

    // MARK: - Code

    func testCodeBlockIsFixedPitchWithBackground() {
        let storage = styledStorage("```swift\nlet x = 1\n```")
        XCTAssertTrue(font(storage, at: 0).isFixedPitch)
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(MDAttr.codeBlock, at: 0, effectiveRange: nil) as? String, "swift")
    }

    func testInlineCodeIsFixedPitch() {
        // Storage text: "Some code here".
        let storage = styledStorage("Some `code` here")
        XCTAssertTrue(font(storage, at: 5).isFixedPitch)
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: 5, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(MDAttr.inlineCode, at: 5, effectiveRange: nil) as? Bool, true)
        // Surrounding text stays proportional without a background.
        XCTAssertFalse(font(storage, at: 0).isFixedPitch)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    // MARK: - Links, lists, rules, raw blocks

    func testLinkIsTintedAndUnderlined() {
        let storage = styledStorage("[text](https://example.com)")
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .systemBlue
        )
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNotNil(storage.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testListIndentLeavesRoomForMarker() {
        let storage = styledStorage("- item")
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
        XCTAssertLessThan(style?.firstLineHeadIndent ?? 0, style?.headIndent ?? 0)
        XCTAssertEqual(style?.textLists.count, 1, "list semantics must be preserved")
    }

    func testThematicBreakBecomesRuleAttachment() {
        let storage = styledStorage("---")
        XCTAssertTrue(storage.attribute(.attachment, at: 0, effectiveRange: nil) is MDRuleAttachment)
        XCTAssertEqual(storage.attribute(MDAttr.thematicBreak, at: 0, effectiveRange: nil) as? Bool, true)
        // The visual swap must not change serialization.
        XCTAssertEqual(MarkdownSerializer.serialize(storage), "---\n")
    }

    func testRawBlockLooksDistinct() {
        let storage = styledStorage("<div>\nhello\n</div>")
        XCTAssertTrue(font(storage, at: 0).isFixedPitch)
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .tertiaryLabelColor
        )
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(MDAttr.rawBlock, at: 0, effectiveRange: nil))
    }

    // MARK: - Idempotency

    /// Styling is derived from semantics, so a second pass changes nothing.
    func testStylingIsIdempotent() {
        // Storage text: "Title\nSome bold and code.\nQuote" — indices cover
        // heading, plain, bold, inline code and quote runs.
        let storage = styledStorage("# Title\n\nSome **bold** and `code`.\n\n> Quote")
        let indices = [0, 7, 12, 21, 27]
        let before = indices.map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary }
        StyleEngine.styleAll(storage)
        let after = indices.map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary }
        XCTAssertEqual(before, after)
    }
}
