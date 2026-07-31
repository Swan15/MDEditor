import AppKit

/// Visual styling derived from the semantic Markdown attributes.
///
/// Styling is purely visual: it never adds, removes or rewrites the semantic
/// attributes (`MDAttr` keys, `.link`, `.strikethroughStyle`, text lists and
/// table blocks) that the serializer reads. It only sets fonts (preserving
/// bold/italic traits already present), colors, indents and spacing, so
/// re-styling a range is idempotent and cheap enough to run on every edit.
enum StyleEngine {
    // MARK: - Fonts

    /// Live font preferences, installed by `AppState` at launch. Nil in
    /// tests and headless use, which yields the historical defaults (13 pt
    /// system body, headings [26, 22, 18, 16, 14, 13], 12 pt code).
    /// Static access happens on the main thread only (styling is view-side).
    nonisolated(unsafe) static var fontSettings: AppSettings?

    /// Body text size; every other size derives from the block type.
    static var bodySize: CGFloat { fontSettings?.editorFontSize ?? AppSettings.defaultFontSize }

    /// Body font for ordinary paragraphs.
    static var bodyFont: NSFont {
        (fontSettings?.editorFontChoice ?? .system).font(size: bodySize)
    }

    /// Font for code blocks, raw blocks and inline code.
    static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: max(bodySize - 1, 9), weight: .regular) }

    /// Heading sizes at the default body size; other sizes scale
    /// proportionally (rounded to half points) so ratios stay constant.
    private static let baseHeadingSizes: [CGFloat] = [26, 22, 18, 16, 14, 13]

    /// Point sizes for heading levels 1–6.
    static var headingSizes: [CGFloat] {
        baseHeadingSizes.map { (($0 * bodySize / AppSettings.defaultFontSize) * 2).rounded() / 2 }
    }

    /// Font for a heading level (clamped to 1–6).
    static func headingFont(level: Int) -> NSFont {
        NSFont.systemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1])
    }

    /// Faux-bold stroke for headings, as a percentage of the point size.
    ///
    /// Headings must look bold without the bold *font trait*: the serializer
    /// derives `**…**` from font traits, so a truly bold heading font would
    /// silently wrap every heading in emphasis markers on save.
    static let headingStroke: CGFloat = -2.5

    // MARK: - Metrics

    /// Spacing after a body paragraph.
    static let bodySpacing: CGFloat = 6

    /// Spacing before/after headings (levels 1–6).
    static let headingSpacingBefore: [CGFloat] = [20, 16, 14, 12, 10, 8]
    static let headingSpacingAfter: [CGFloat] = [8, 6, 6, 4, 4, 4]

    /// Indent per block-quote depth.
    static let quoteIndent: CGFloat = 16

    /// Indent per list nesting level; the marker hangs one step to the left.
    static let listIndent: CGFloat = 24

    // MARK: - Colors

    /// Subtle background for code (blocks and inline) in both appearances.
    static var codeBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }

    /// Link tint (raw destinations stay semantic in `.link`; this is visual).
    static var linkColor: NSColor { NSColor.systemBlue }

    // MARK: - Table chrome

    /// Gridline color for table borders (adaptive).
    static var tableGridColor: NSColor { NSColor.separatorColor }

    /// Header-row background (adaptive, subtle).
    static var tableHeaderBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }

    /// Cell padding on all four edges.
    static let tableCellPadding: CGFloat = 5

    /// Faux-bold stroke for header cells (same trick as headings: the
    /// serializer derives `**` from font traits, so real bold is forbidden).
    static let tableHeaderStroke: CGFloat = -2.5

    /// Visual attributes owned by the style engine: removed and re-applied on
    /// every pass. Semantic attributes are never in this list.
    private static let managedAttributes: [NSAttributedString.Key] = [
        .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor, .strokeWidth
    ]

    // MARK: - Styling

    /// Re-styles the `\n`-delimited paragraphs intersecting `range`.
    static func style(_ textStorage: NSTextStorage, range: NSRange) {
        guard textStorage.length > 0 else { return }
        let fullRange = textStorage.mdParagraphRange(for: range)
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        textStorage.enumerateMDParagraphs(in: fullRange) { paragraph in
            styleParagraph(textStorage, range: paragraph)
        }
    }

    /// Styles the whole document (used after loading content).
    static func styleAll(_ textStorage: NSTextStorage) {
        guard textStorage.length > 0 else { return }
        style(textStorage, range: NSRange(location: 0, length: textStorage.length))
    }

    /// Styles one paragraph (range includes the terminating newline).
    private static func styleParagraph(_ storage: NSTextStorage, range paragraph: NSRange) {
        let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)

        if attributes[MDAttr.thematicBreak] as? Bool == true {
            styleRuleParagraph(storage, range: paragraph)
            return
        }

        let headingLevel = attributes[MDAttr.headingLevel] as? Int
        let quoteDepth = attributes[MDAttr.blockQuoteDepth] as? Int ?? 0
        let isRawBlock = attributes[MDAttr.rawBlock] != nil
        let isCodeBlock = attributes[MDAttr.codeBlock] != nil
        let isMonospaceBlock = isRawBlock || isCodeBlock
        let existingStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        let lists = existingStyle?.textLists ?? []
        let isTableCell = !(existingStyle?.textBlocks.isEmpty ?? true)

        for key in managedAttributes {
            storage.removeAttribute(key, range: paragraph)
        }

        // Paragraph-level color and background.
        let textColor: NSColor = isRawBlock ? .tertiaryLabelColor
            : quoteDepth > 0 ? .secondaryLabelColor
            : .labelColor
        storage.addAttribute(.foregroundColor, value: textColor, range: paragraph)
        if isMonospaceBlock {
            storage.addAttribute(.backgroundColor, value: codeBackground, range: paragraph)
        }
        if headingLevel != nil {
            storage.addAttribute(.strokeWidth, value: headingStroke, range: paragraph)
        }

        // Paragraph style: merge visual fields, keeping textLists/textBlocks.
        let style = (existingStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if let headingLevel, !isTableCell {
            let index = min(max(headingLevel, 1), 6) - 1
            style.paragraphSpacingBefore = headingSpacingBefore[index]
            style.paragraphSpacing = headingSpacingAfter[index]
        } else {
            style.paragraphSpacingBefore = 0
            // Table cells and list items stay tight; the breathing room
            // around a list comes from the adjacent blocks' own spacing.
            style.paragraphSpacing = (isTableCell || !lists.isEmpty) ? 0 : bodySpacing
        }
        let quoteOffset = quoteIndent * CGFloat(quoteDepth)
        if !lists.isEmpty {
            style.headIndent = quoteOffset + listIndent * CGFloat(lists.count)
            style.firstLineHeadIndent = quoteOffset + listIndent * CGFloat(lists.count - 1)
        } else {
            style.headIndent = quoteOffset
            style.firstLineHeadIndent = quoteOffset
        }
        if isTableCell {
            applyTableChrome(storage, paragraph: paragraph, style: style, attributes: attributes)
        }
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)

        // Run-level styling: fonts (bold/italic traits preserved), inline
        // code background, link tint. Runs are collected first so the string
        // is never mutated mid-enumeration.
        let baseFont = isMonospaceBlock ? codeFont : (headingLevel.map(headingFont) ?? bodyFont)
        var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: paragraph, options: []) { runAttributes, range, _ in
            runs.append((range, runAttributes))
        }
        for (range, runAttributes) in runs {
            let traits = (runAttributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let isInlineCode = runAttributes[MDAttr.inlineCode] as? Bool == true
            var font = isInlineCode ? codeFont : baseFont
            if traits.contains(.bold) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: font, range: range)
            if isInlineCode && !isMonospaceBlock {
                storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
            }
            if runAttributes[.link] != nil {
                storage.addAttribute(.foregroundColor, value: linkColor, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    // MARK: - Table chrome

    /// Word-like table styling: gridlines and padding on the (shared) table
    /// and block objects, header-row shading plus faux-bold text, and column
    /// alignment from `mdTableAlignments`. The block/table objects carry the
    /// chrome (not string attributes), so this is idempotent and survives the
    /// paragraph-style merge above; controller-inserted blocks get their
    /// chrome here on the next pass.
    private static func applyTableChrome(
        _ storage: NSTextStorage,
        paragraph: NSRange,
        style: NSMutableParagraphStyle,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let isHeader = attributes[MDAttr.tableHeader] as? Bool == true
        let alignments = attributes[MDAttr.tableAlignments] as? [String] ?? []
        let edges: [NSRectEdge] = [.minX, .maxX, .minY, .maxY]
        for case let block as NSTextTableBlock in style.textBlocks {
            let table = block.table
            table.setWidth(1, type: .absoluteValueType, for: .border)
            table.hidesEmptyCells = false // empty cells keep their gridlines
            for edge in edges {
                table.setBorderColor(tableGridColor, for: edge)
            }
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setWidth(tableCellPadding, type: .absoluteValueType, for: .padding)
            for edge in edges {
                block.setBorderColor(tableGridColor, for: edge)
            }
            block.backgroundColor = isHeader ? tableHeaderBackground : .clear
            if block.startingColumn < alignments.count {
                switch alignments[block.startingColumn] {
                case "left": style.alignment = .left
                case "center": style.alignment = .center
                case "right": style.alignment = .right
                default: style.alignment = .natural
                }
            }
        }
        if isHeader {
            storage.addAttribute(.strokeWidth, value: tableHeaderStroke, range: paragraph)
        }
    }

    // MARK: - Thematic breaks

    /// Shared rule attachment (immutable; bounds are computed per layout).
    nonisolated(unsafe) static let ruleAttachment = MDRuleAttachment(data: nil, ofType: nil)

    /// Tiny font for the rule paragraph, so the rule sits tight vertically.
    private static var ruleFont: NSFont { NSFont.systemFont(ofSize: 6) }

    /// Styles a thematic-break paragraph: the placeholder NBSP becomes a
    /// full-width rule attachment (a 1:1 character swap, so ranges stay
    /// valid). Idempotent — an existing attachment is left alone.
    private static func styleRuleParagraph(_ storage: NSTextStorage, range paragraph: NSRange) {
        let string = storage.string as NSString
        var contentRange = paragraph
        if contentRange.length > 0, string.character(at: NSMaxRange(contentRange) - 1) == 0x0A {
            contentRange.length -= 1
        }
        if string.substring(with: contentRange) == "\u{00A0}" {
            storage.replaceCharacters(in: contentRange, with: NSAttributedString(
                string: "\u{FFFC}",
                attributes: [
                    .attachment: ruleAttachment,
                    .font: ruleFont,
                    MDAttr.thematicBreak: true
                ]
            ))
        }
        for key in managedAttributes {
            storage.removeAttribute(key, range: paragraph)
        }
        storage.addAttribute(.font, value: ruleFont, range: paragraph)
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: paragraph)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }
}

// MARK: - Paragraph ranges

extension NSAttributedString {
    /// Calls `body` with the range of every `\n`-delimited paragraph
    /// intersecting `range`, each including its terminating newline.
    ///
    /// Paragraphs split on `\n` only — never on U+2028, which code and raw
    /// blocks use as an in-paragraph line separator (mirrors the serializer;
    /// `NSString.paragraphRange` would split on U+2028).
    func enumerateMDParagraphs(in range: NSRange, using body: (NSRange) -> Void) {
        let string = self.string as NSString
        let length = string.length
        guard length > 0, range.location != NSNotFound, range.location >= 0 else { return }
        let clampedEnd = min(max(NSMaxRange(range), 0), length)
        var start = min(range.location, length)
        while start > 0, string.character(at: start - 1) != 0x0A { start -= 1 }
        var location = start
        while location < length {
            var newline = location
            while newline < length, string.character(at: newline) != 0x0A { newline += 1 }
            let paragraph = NSRange(
                location: location,
                length: newline - location + (newline < length ? 1 : 0)
            )
            body(paragraph)
            if NSMaxRange(paragraph) >= clampedEnd { break }
            location = NSMaxRange(paragraph)
        }
    }

    /// Union of the paragraph ranges intersecting `range`.
    func mdParagraphRange(for range: NSRange) -> NSRange {
        var union: NSRange?
        enumerateMDParagraphs(in: range) { paragraph in
            union = union.map { NSUnionRange($0, paragraph) } ?? paragraph
        }
        return union ?? NSRange(location: min(max(range.location, 0), length), length: 0)
    }

    /// Ranges of all paragraphs intersecting `range`.
    func mdParagraphRanges(in range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        enumerateMDParagraphs(in: range) { ranges.append($0) }
        return ranges
    }
}

// MARK: - Rule attachment

/// Text attachment rendering a full-width horizontal rule (thematic break).
///
/// The width is computed per layout pass from the proposed line fragment, so
/// the rule always spans the available width regardless of window size.
final class MDRuleAttachment: NSTextAttachment {
    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: nil, ofType: nil)
        image = MDRuleAttachment.makeImage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Stretches the rule across the rest of the line fragment.
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let width = max(lineFrag.width - position.x - 1, 1)
        return CGRect(x: 0, y: 2, width: width, height: 2)
    }

    /// 1×1 gray pixel, stretched to the rule's bounds by the layout manager.
    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor(white: 0, alpha: 0.3).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        return image
    }
}
