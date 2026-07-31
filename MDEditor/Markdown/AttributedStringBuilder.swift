import AppKit
import Markdown

/// Builds the editing source of truth (an `NSAttributedString` with semantic
/// attributes) from a parsed Markdown document.
///
/// Block structure is flattened into paragraphs separated by single `\n`
/// characters; what each paragraph *is* is described by `MDAttr` keys,
/// `paragraphStyle.textLists` (lists) and `paragraphStyle.textBlocks`
/// (tables). Multi-line block content (code, raw blocks) keeps its newlines
/// as U+2028 line separators so one block always stays one paragraph.
enum AttributedStringBuilder {
    /// Converts a parsed Markdown document into an attributed string.
    static func build(_ parsed: ParsedDocument) -> NSAttributedString {
        var builder = Builder(parsed: parsed)
        builder.visit(parsed.document)
        return builder.finish()
    }
}

/// Line separator standing in for `\n` inside a single paragraph.
private let lineSeparator = "\u{2028}"

private struct Builder: MarkupWalker {
    let parsed: ParsedDocument
    let output = NSMutableAttributedString()

    /// Start index of the paragraph currently being appended.
    var paragraphStart = 0

    /// Paragraph-level semantic attributes for the current paragraph.
    var blockAttributes: [NSAttributedString.Key: Any] = [:]

    /// Paragraph style (lists / table blocks) for the current paragraph.
    var paragraphStyle: NSMutableParagraphStyle?

    // Inline state (save/restored around container visits).
    var isBold = false
    var isItalic = false
    var isStrikethrough = false
    var linkDestination: String?
    var linkTitle: String?

    // Block state.
    var quoteDepth = 0
    var listStack: [NSTextList] = []
    var pendingItemStart = false
    var pendingCheckbox: Checkbox?

    // MARK: - Paragraph lifecycle

    mutating func beginParagraph() {
        paragraphStart = output.length
        blockAttributes = [:]
        paragraphStyle = nil
    }

    mutating func endParagraph() {
        if quoteDepth > 0 {
            blockAttributes[MDAttr.blockQuoteDepth] = quoteDepth
        }
        if !listStack.isEmpty {
            let style = paragraphStyle ?? NSMutableParagraphStyle()
            style.textLists = listStack
            paragraphStyle = style
            // Explicit on every list paragraph so continuation paragraphs
            // (second and later paragraphs of one item) are distinguishable.
            blockAttributes[MDAttr.listItemStart] = pendingItemStart
            if let checkbox = pendingCheckbox {
                blockAttributes[MDAttr.checkbox] = (checkbox == .checked)
            }
        }
        pendingItemStart = false
        pendingCheckbox = nil
        output.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: paragraphStart, length: output.length - paragraphStart)
        for (key, value) in blockAttributes {
            output.addAttribute(key, value: value, range: range)
        }
        if let paragraphStyle {
            output.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        }
    }

    /// Drops the trailing paragraph separator once the document is built —
    /// unless it constitutes an entire empty table-cell paragraph: dropping
    /// it would destroy the cell (a paragraph with no characters is
    /// invisible to the paragraph enumeration).
    func finish() -> NSAttributedString {
        if output.length > 0, output.string.hasSuffix("\n") {
            let string = output.string as NSString
            let isEmptyParagraph = output.length == 1 || string.character(at: output.length - 2) == 0x0A
            let attributes = output.attributes(at: output.length - 1, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let isTableCell = style?.textBlocks.contains(where: { $0 is NSTextTableBlock }) ?? false
            if !(isEmptyParagraph && isTableCell) {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }
        return output
    }

    // MARK: - Inline appends

    func currentInlineAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MDFont.make(bold: isBold, italic: isItalic)
        ]
        if isStrikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let linkDestination {
            // `.link` is a URL when the destination survives URL conversion
            // byte-for-byte; otherwise keep the raw string (a lenient URL
            // parse would percent-encode e.g. spaces and corrupt the text).
            if let url = URL(string: linkDestination), url.absoluteString == linkDestination {
                attributes[.link] = url
            } else {
                attributes[.link] = linkDestination as NSString
            }
            if let linkTitle {
                attributes[MDAttr.linkTitle] = linkTitle
            }
        }
        return attributes
    }

    func append(_ text: String) {
        output.append(NSAttributedString(string: text, attributes: currentInlineAttributes()))
    }

    // MARK: - Document and basic blocks

    mutating func visitDocument(_ document: Document) {
        descendInto(document)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        guard !containsUnsupportedInline(paragraph) else {
            emitRawBlock(paragraph)
            return
        }
        beginParagraph()
        descendInto(paragraph)
        endParagraph()
    }

    mutating func visitHeading(_ heading: Heading) {
        guard !containsUnsupportedInline(heading) else {
            emitRawBlock(heading)
            return
        }
        beginParagraph()
        blockAttributes[MDAttr.headingLevel] = heading.level
        descendInto(heading)
        endParagraph()
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        beginParagraph()
        blockAttributes[MDAttr.codeBlock] = codeBlock.language ?? ""
        // cmark hands back the content with exactly one trailing newline.
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        output.append(NSAttributedString(
            string: code.replacingOccurrences(of: "\n", with: lineSeparator),
            attributes: [.font: MDFont.make(monospaced: true)]
        ))
        endParagraph()
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        beginParagraph()
        blockAttributes[MDAttr.thematicBreak] = true
        output.append(NSAttributedString(string: "\u{00A0}"))
        endParagraph()
    }

    // MARK: - Raw blocks (unsupported constructs preserved verbatim)

    /// Emits a paragraph carrying the node's original source text, which the
    /// serializer re-emits verbatim. Display text mirrors the source with
    /// newlines replaced by U+2028 so the block stays a single paragraph.
    mutating func emitRawBlock(_ markup: Markup) {
        guard var raw = parsed.sourceSlice(markup.range) else {
            descendInto(markup)
            return
        }
        while raw.hasSuffix("\n") { raw.removeLast() }
        beginParagraph()
        blockAttributes[MDAttr.rawBlock] = raw
        output.append(NSAttributedString(
            string: raw.replacingOccurrences(of: "\n", with: lineSeparator),
            attributes: [.font: MDFont.make(monospaced: true)]
        ))
        endParagraph()
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) { emitRawBlock(html) }
    mutating func visitBlockDirective(_ blockDirective: BlockDirective) { emitRawBlock(blockDirective) }
    mutating func visitCustomBlock(_ customBlock: CustomBlock) { emitRawBlock(customBlock) }
    mutating func visitDoxygenDiscussion(_ doxygenDiscussion: DoxygenDiscussion) { emitRawBlock(doxygenDiscussion) }
    mutating func visitDoxygenNote(_ doxygenNote: DoxygenNote) { emitRawBlock(doxygenNote) }
    mutating func visitDoxygenAbstract(_ doxygenAbstract: DoxygenAbstract) { emitRawBlock(doxygenAbstract) }
    mutating func visitDoxygenParameter(_ doxygenParam: DoxygenParameter) { emitRawBlock(doxygenParam) }
    mutating func visitDoxygenReturns(_ doxygenReturns: DoxygenReturns) { emitRawBlock(doxygenReturns) }

    /// Defensive fallback: inline HTML inside an otherwise supported
    /// paragraph is unreachable (the paragraph becomes a raw block first),
    /// but never drop text if that changes.
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { append(inlineHTML.rawHTML) }
    mutating func visitCustomInline(_ customInline: CustomInline) {}
    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {}

    // MARK: - Inline leaves

    mutating func visitText(_ text: Text) {
        append(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        append(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        append(lineSeparator)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        var attributes = currentInlineAttributes()
        attributes[MDAttr.inlineCode] = true
        attributes[.font] = MDFont.make(bold: isBold, italic: isItalic, monospaced: true)
        // cmark may report multi-line code spans; keep them single-paragraph.
        let code = inlineCode.code.replacingOccurrences(of: "\n", with: " ")
        output.append(NSAttributedString(string: code, attributes: attributes))
    }

    // MARK: - Inline containers

    mutating func visitStrong(_ strong: Strong) {
        let old = isBold
        isBold = true
        descendInto(strong)
        isBold = old
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        let old = isItalic
        isItalic = true
        descendInto(emphasis)
        isItalic = old
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        let old = isStrikethrough
        isStrikethrough = true
        descendInto(strikethrough)
        isStrikethrough = old
    }

    mutating func visitLink(_ link: Link) {
        let oldDestination = linkDestination
        let oldTitle = linkTitle
        linkDestination = link.destination
        linkTitle = link.title
        descendInto(link)
        linkDestination = oldDestination
        linkTitle = oldTitle
    }

    mutating func visitImage(_ image: Image) {
        let attachment = MDImageAttachment(
            source: image.source ?? "",
            altText: plainText(of: image),
            title: image.title
        )
        var attributes = currentInlineAttributes()
        attributes[.attachment] = attachment
        output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
    }

    // MARK: - Lists

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        listStack.append(NSTextList(markerFormat: .disc, options: 0))
        descendInto(unorderedList)
        listStack.removeLast()
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let textList = NSTextList(markerFormat: .decimal, options: 0)
        textList.startingItemNumber = Int(orderedList.startIndex)
        listStack.append(textList)
        descendInto(orderedList)
        listStack.removeLast()
    }

    mutating func visitListItem(_ listItem: ListItem) {
        pendingItemStart = true
        pendingCheckbox = listItem.checkbox
        descendInto(listItem)
        pendingItemStart = false
        pendingCheckbox = nil
    }

    // MARK: - Block quotes

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        quoteDepth += 1
        descendInto(blockQuote)
        quoteDepth -= 1
    }

    // MARK: - Tables

    mutating func visitTable(_ table: Table) {
        guard !containsUnsupportedInline(table) else {
            emitRawBlock(table)
            return
        }
        let textTable = NSTextTable()
        textTable.numberOfColumns = table.maxColumnCount
        let alignments = table.columnAlignments.map { alignment -> String in
            switch alignment {
            case .left: return "left"
            case .center: return "center"
            case .right: return "right"
            case nil: return ""
            }
        }
        for (column, cell) in table.head.cells.enumerated() {
            emitCell(cell, table: textTable, row: 0, column: column, isHeader: true, alignments: alignments)
        }
        for (rowIndex, row) in table.body.rows.enumerated() {
            for (column, cell) in row.cells.enumerated() {
                emitCell(cell, table: textTable, row: rowIndex + 1, column: column, isHeader: false, alignments: alignments)
            }
        }
    }

    mutating func emitCell(
        _ cell: Table.Cell,
        table: NSTextTable,
        row: Int,
        column: Int,
        isHeader: Bool,
        alignments: [String]
    ) {
        beginParagraph()
        let style = NSMutableParagraphStyle()
        style.textBlocks = [NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: 1,
            startingColumn: column,
            columnSpan: 1
        )]
        paragraphStyle = style
        if isHeader {
            blockAttributes[MDAttr.tableHeader] = true
        }
        blockAttributes[MDAttr.tableAlignments] = alignments
        descendInto(cell)
        endParagraph()
    }

    // MARK: - Unsupported-inline detection

    /// True when the subtree contains inline markup that has no WYSIWYG
    /// representation; the enclosing block becomes a raw block instead.
    func containsUnsupportedInline(_ markup: Markup) -> Bool {
        if markup is InlineHTML || markup is CustomInline || markup is SymbolLink || markup is InlineAttributes {
            return true
        }
        return markup.children.contains(where: containsUnsupportedInline)
    }

    // MARK: - Helpers

    /// Plain text of an inline subtree (used for image alt text).
    func plainText(of markup: Markup) -> String {
        var result = ""
        for child in markup.children {
            switch child {
            case let text as Text:
                result += text.string
            case let code as InlineCode:
                result += code.code
            case is SoftBreak, is LineBreak:
                result += " "
            default:
                result += plainText(of: child)
            }
        }
        return result
    }
}
