import AppKit

/// Word-like key handling (Return, Tab, Shift-Tab, Backspace) on the live
/// text storage.
///
/// Each method decides whether the keystroke gets custom behavior — returning
/// a `Result` describing the mutation — or falls through to `NSTextView`'s
/// default handling (returning nil). Everything runs headless on
/// `NSTextStorage` + selection, exactly like `FormatCommands`; the view layer
/// only applies the returned selection and typing attributes.
///
/// The paragraph model is sacred: blocks stay `\n`-separated paragraphs and
/// multi-line content inside a block (code, table cells) uses U+2028, so the
/// serializer keeps producing canonical GFM after every behavior.
enum EditingBehavior {
    // MARK: - Context and result

    /// Everything a behavior needs from the view layer.
    struct Context {
        /// The live text storage.
        let storage: NSTextStorage
        /// The current selection.
        var selection: NSRange
        /// The view's typing attributes. They stand in for paragraph
        /// attributes when the cursor sits in a trailing empty paragraph,
        /// which has no characters to carry attributes (e.g. the fresh
        /// second item of a list, before its first character is typed).
        var typingAttributes: [NSAttributedString.Key: Any]
        /// Undo manager receiving a content snapshot before each mutation.
        var undoManager: UndoManager?
        /// Restores the view-side selection (and typing attributes) on undo.
        var restoreSelection: ((NSRange) -> Void)?

        init(
            storage: NSTextStorage,
            selection: NSRange,
            typingAttributes: [NSAttributedString.Key: Any] = [:],
            undoManager: UndoManager? = nil,
            restoreSelection: ((NSRange) -> Void)? = nil
        ) {
            self.storage = storage
            self.selection = selection
            self.typingAttributes = typingAttributes
            self.undoManager = undoManager
            self.restoreSelection = restoreSelection
        }
    }

    /// What the view layer applies after a handled keystroke.
    struct Result {
        /// New selection.
        var selection: NSRange
        /// Typing attributes to install; nil leaves them unchanged.
        var typingAttributes: [NSAttributedString.Key: Any]?
        /// True when the storage changed (drives dirty marking, the status
        /// bar recount and undo-coalescing breaks).
        var mutated: Bool
    }

    // MARK: - Return

    /// Which custom Return behavior applies to a paragraph.
    private enum NewlineAction {
        case thematicBreak, codeBlock, tableCell
        case listExit, listContinue
        case heading
        case quoteExit, quoteContinue
        case body

        var undoActionName: String {
            switch self {
            case .listExit, .quoteExit: return "Clear Formatting"
            case .thematicBreak: return "New Paragraph"
            default: return "Typing"
            }
        }
    }

    /// Return key: continue/exit lists, quotes and code blocks; end-of-heading
    /// drops to body; mid-heading splits (both halves stay headings). Plain
    /// body text with a collapsed selection falls through to the default.
    static func insertNewline(in context: Context) -> Result? {
        let storage = context.storage
        guard storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        let action = classify(paragraph(at: cursor, in: context))
        // A non-collapsed selection is always handled here (delete + break);
        // collapsed plain-body Return stays native for typing-undo coalescing.
        guard action != .body || context.selection.length > 0 else { return nil }

        beginMutation(action.undoActionName, in: context)
        if context.selection.length > 0 {
            storage.replaceCharacters(in: context.selection, with: "")
        }
        let paragraph = paragraph(at: cursor, in: context)
        switch action {
        case .thematicBreak: return newlineAfterThematicBreak(paragraph, in: context)
        case .codeBlock: return newlineInCodeBlock(paragraph, at: cursor, in: context)
        case .tableCell: return insertLineSeparator(at: cursor, in: context)
        case .listExit: return exitList(paragraph, in: context)
        case .listContinue: return continueList(paragraph, at: cursor, in: context)
        case .heading: return newlineInHeading(paragraph, at: cursor, in: context)
        case .quoteExit: return exitQuote(paragraph, in: context)
        case .quoteContinue: return continueQuote(at: cursor, in: context)
        case .body: return newlineInBody(at: cursor, in: context)
        }
    }

    /// Maps a paragraph to its Return behavior.
    private static func classify(_ paragraph: Paragraph) -> NewlineAction {
        if paragraph.isThematicBreak { return .thematicBreak }
        if paragraph.codeBlock != nil || paragraph.isRawBlock { return .codeBlock }
        if paragraph.isTableCell { return .tableCell }
        if !paragraph.textLists.isEmpty {
            return paragraph.content.length == 0 ? .listExit : .listContinue
        }
        if paragraph.headingLevel != nil { return .heading }
        if paragraph.quoteDepth > 0 {
            return paragraph.content.length == 0 ? .quoteExit : .quoteContinue
        }
        return .body
    }

    // MARK: - Return: lists

    /// Return on a non-empty list item: split/continue with the same list
    /// objects (shared identity keeps the serialized list tight). A split-off
    /// tail becomes a fresh, unchecked item.
    private static func continueList(_ paragraph: Paragraph, at cursor: Int, in context: Context) -> Result {
        let storage = context.storage
        let contentEnd = NSMaxRange(paragraph.content)
        storage.insert(NSAttributedString(string: "\n", attributes: attributesForInsertion(at: cursor, in: storage)), at: cursor)
        let tail = NSRange(location: cursor + 1, length: contentEnd - cursor)
        if tail.length > 0 {
            storage.addAttribute(MDAttr.listItemStart, value: true, range: tail)
            if paragraph.hasCheckbox {
                storage.addAttribute(MDAttr.checkbox, value: false, range: tail)
            }
        }
        var typing = typingAttributesAfterBreak(at: cursor + 1, fallbackCursor: cursor, in: storage)
        typing[MDAttr.listItemStart] = true
        if paragraph.hasCheckbox {
            typing[MDAttr.checkbox] = false
        }
        StyleEngine.style(storage, range: twoParagraphRange(around: cursor, in: storage))
        return Result(selection: NSRange(location: cursor + 1, length: 0), typingAttributes: typing, mutated: true)
    }

    /// Return on an empty list item exits the list (Word behavior): strip the
    /// list formatting off the paragraph instead of inserting a break. A
    /// trailing empty item has no characters; resetting the typing attributes
    /// is all there is to do.
    private static func exitList(_ paragraph: Paragraph, in context: Context) -> Result {
        let typing = bodyTypingAttributes(quoteDepth: paragraph.quoteDepth)
        guard paragraph.range.length > 0 else {
            return Result(selection: context.selection, typingAttributes: typing, mutated: false)
        }
        let storage = context.storage
        storage.beginEditing()
        if let style = mutableParagraphStyle(at: paragraph.range.location, in: storage), !style.textLists.isEmpty {
            style.textLists = []
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
        }
        storage.removeAttribute(MDAttr.listItemStart, range: paragraph.range)
        storage.removeAttribute(MDAttr.checkbox, range: paragraph.range)
        storage.endEditing()
        StyleEngine.style(storage, range: paragraph.range)
        return Result(selection: context.selection, typingAttributes: typing, mutated: true)
    }

    // MARK: - Return: headings

    /// Return at the end of a heading starts a body paragraph; Return in the
    /// middle splits it and both halves stay headings (Word behavior). A
    /// containing block quote is kept in both cases.
    private static func newlineInHeading(_ paragraph: Paragraph, at cursor: Int, in context: Context) -> Result {
        let storage = context.storage
        let atEnd = cursor >= NSMaxRange(paragraph.content)
        storage.insert(NSAttributedString(string: "\n", attributes: attributesForInsertion(at: cursor, in: storage)), at: cursor)
        if atEnd {
            // The paragraph after the break (an existing empty one, or the
            // trailing paragraph) must not inherit the heading.
            let following = storage.mdParagraphRange(for: NSRange(location: cursor + 1, length: 0))
            if following.length > 0, following.location < storage.length {
                storage.removeAttribute(MDAttr.headingLevel, range: following)
            }
            StyleEngine.style(storage, range: twoParagraphRange(around: cursor, in: storage))
            return Result(
                selection: NSRange(location: cursor + 1, length: 0),
                typingAttributes: bodyTypingAttributes(quoteDepth: paragraph.quoteDepth),
                mutated: true
            )
        }
        // Mid-heading split: the heading attribute rides the characters, so
        // both halves stay headings without any fixup.
        let typing = typingAttributesAfterBreak(at: cursor + 1, fallbackCursor: cursor, in: storage)
        StyleEngine.style(storage, range: twoParagraphRange(around: cursor, in: storage))
        return Result(selection: NSRange(location: cursor + 1, length: 0), typingAttributes: typing, mutated: true)
    }

    // MARK: - Return: block quotes

    /// Return inside a block quote continues it at the same depth (the depth
    /// attribute rides the characters; the typing attributes cover the
    /// empty-tail case).
    private static func continueQuote(at cursor: Int, in context: Context) -> Result {
        let storage = context.storage
        storage.insert(NSAttributedString(string: "\n", attributes: attributesForInsertion(at: cursor, in: storage)), at: cursor)
        let typing = typingAttributesAfterBreak(at: cursor + 1, fallbackCursor: cursor, in: storage)
        StyleEngine.style(storage, range: twoParagraphRange(around: cursor, in: storage))
        return Result(selection: NSRange(location: cursor + 1, length: 0), typingAttributes: typing, mutated: true)
    }

    /// Return on an empty quoted paragraph exits to body.
    private static func exitQuote(_ paragraph: Paragraph, in context: Context) -> Result {
        guard paragraph.range.length > 0 else {
            return Result(selection: context.selection, typingAttributes: bodyTypingAttributes(), mutated: false)
        }
        let storage = context.storage
        storage.removeAttribute(MDAttr.blockQuoteDepth, range: paragraph.range)
        StyleEngine.style(storage, range: paragraph.range)
        return Result(selection: context.selection, typingAttributes: bodyTypingAttributes(), mutated: true)
    }

    // MARK: - Return: code and raw blocks

    /// Return inside a code block inserts a U+2028 line separator, keeping
    /// the block a single paragraph. Return on the block's empty last line
    /// drops that line and leaves the block for body text; Return on an
    /// entirely empty code paragraph converts it to body.
    private static func newlineInCodeBlock(_ paragraph: Paragraph, at cursor: Int, in context: Context) -> Result {
        let storage = context.storage
        let string = storage.string as NSString

        if paragraph.content.length == 0, paragraph.codeBlock != nil {
            // Empty code paragraph: convert to body.
            guard paragraph.range.length > 0 else {
                return Result(selection: context.selection, typingAttributes: bodyTypingAttributes(), mutated: false)
            }
            storage.removeAttribute(MDAttr.codeBlock, range: paragraph.range)
            StyleEngine.style(storage, range: paragraph.range)
            return Result(selection: context.selection, typingAttributes: bodyTypingAttributes(), mutated: true)
        }

        // Cursor at the end of the content with an empty last line (trailing
        // U+2028): drop the empty line and exit to a body paragraph.
        let contentEnd = NSMaxRange(paragraph.content)
        if cursor == contentEnd, contentEnd > paragraph.content.location,
           string.character(at: contentEnd - 1) == 0x2028 {
            storage.deleteCharacters(in: NSRange(location: contentEnd - 1, length: 1))
            storage.insert(NSAttributedString(string: "\n", attributes: attributesForInsertion(at: contentEnd - 1, in: storage)), at: contentEnd - 1)
            StyleEngine.style(storage, range: twoParagraphRange(around: contentEnd - 1, in: storage))
            return Result(
                selection: NSRange(location: contentEnd, length: 0),
                typingAttributes: bodyTypingAttributes(),
                mutated: true
            )
        }

        // Ordinary Return inside code (or a raw block, whose single-paragraph
        // model is the same): a line separator.
        return insertLineSeparator(at: cursor, in: context)
    }

    // MARK: - Return: table cells, thematic breaks, body

    /// Return inside a table cell inserts a U+2028 line separator within the
    /// cell (serialized as a space; a paragraph break would corrupt the table).
    private static func insertLineSeparator(at cursor: Int, in context: Context) -> Result {
        let attributes = attributesForInsertion(at: cursor, in: context.storage)
        context.storage.insert(NSAttributedString(string: "\u{2028}", attributes: attributes), at: cursor)
        return Result(
            selection: NSRange(location: cursor + 1, length: 0),
            typingAttributes: typingAttributes(from: attributes),
            mutated: true
        )
    }

    /// Return on a horizontal rule starts a fresh body paragraph below it.
    private static func newlineAfterThematicBreak(_ paragraph: Paragraph, in context: Context) -> Result {
        let storage = context.storage
        let paragraphEnd = NSMaxRange(paragraph.range)
        let hasTrailingNewline = paragraph.range.length > paragraph.content.length
        storage.insert(NSAttributedString(string: "\n", attributes: bodyTypingAttributes()), at: paragraphEnd)
        let cursor = hasTrailingNewline ? paragraphEnd : paragraphEnd + 1
        StyleEngine.style(storage, range: twoParagraphRange(around: paragraphEnd, in: storage))
        return Result(selection: NSRange(location: cursor, length: 0), typingAttributes: bodyTypingAttributes(), mutated: true)
    }

    /// Return replacing a selection in plain body text (selection-less body
    /// Return is left to the default implementation).
    private static func newlineInBody(at cursor: Int, in context: Context) -> Result {
        let storage = context.storage
        storage.insert(NSAttributedString(string: "\n", attributes: attributesForInsertion(at: cursor, in: storage)), at: cursor)
        return Result(
            selection: NSRange(location: cursor + 1, length: 0),
            typingAttributes: typingAttributesAfterBreak(at: cursor + 1, fallbackCursor: cursor, in: storage),
            mutated: true
        )
    }

    // MARK: - Tab / Shift-Tab

    /// Tab: inside a table cell, move to the next cell (the last cell
    /// appends a row); inside a list item, indent one level (a fresh
    /// `NSTextList` of the same marker format, appended to `textLists`);
    /// inside a code block, insert a literal tab; anywhere else, swallow
    /// it — a raw tab at line start would reparse as an indented code block.
    static func indent(in context: Context) -> Result? {
        let storage = context.storage
        guard storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        let cursorParagraph = paragraph(at: cursor, in: context)

        // Table cell: Tab is cell navigation, not indentation.
        if cursorParagraph.isTableCell {
            return TableController.moveSelection(forward: true, in: context)
        }

        if cursorParagraph.codeBlock != nil || cursorParagraph.isRawBlock {
            beginMutation("Typing", in: context)
            let attributes = attributesForInsertion(at: cursor, in: storage)
            storage.replaceCharacters(in: context.selection, with: NSAttributedString(string: "\t", attributes: attributes))
            return Result(
                selection: NSRange(location: cursor + 1, length: 0),
                typingAttributes: typingAttributes(from: attributes),
                mutated: true
            )
        }

        let listParagraphs = storage.mdParagraphRanges(in: context.selection).filter { range in
            ((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists.isEmpty) == false
        }
        guard !listParagraphs.isEmpty else {
            // The selection may sit in a trailing empty list item (no
            // characters): indent its not-yet-typed paragraph through the
            // typing attributes.
            if let style = context.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
               let innermost = style.textLists.last {
                var typing = context.typingAttributes
                let indented = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                indented.textLists = style.textLists + [NSTextList(markerFormat: innermost.markerFormat, options: 0)]
                typing[.paragraphStyle] = indented
                typing[MDAttr.listItemStart] = true
                return Result(selection: context.selection, typingAttributes: typing, mutated: false)
            }
            // Body text: swallow the tab.
            return Result(selection: context.selection, typingAttributes: nil, mutated: false)
        }

        beginMutation("Indent", in: context)
        storage.beginEditing()
        for range in listParagraphs {
            guard let style = mutableParagraphStyle(at: range.location, in: storage),
                  let innermost = style.textLists.last else { continue }
            style.textLists.append(NSTextList(markerFormat: innermost.markerFormat, options: 0))
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.addAttribute(MDAttr.listItemStart, value: true, range: range)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: context.selection)
        return Result(selection: context.selection, typingAttributes: nil, mutated: true)
    }

    /// Shift-Tab: inside a table cell, move to the previous cell (swallowed
    /// in the first cell); otherwise outdent every selected list item one
    /// level; outdenting past depth 0 removes the item from the list.
    /// Nothing to outdent falls through to the (harmless) default.
    static func outdent(in context: Context) -> Result? {
        let storage = context.storage
        guard storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)

        // Table cell: Shift-Tab is reverse cell navigation.
        if paragraph(at: cursor, in: context).isTableCell {
            return TableController.moveSelection(forward: false, in: context)
        }
        let listParagraphs = storage.mdParagraphRanges(in: context.selection).filter { range in
            ((storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists.isEmpty) == false
        }
        guard !listParagraphs.isEmpty else {
            // Trailing empty list item: outdent through the typing attributes.
            if let style = context.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
               !style.textLists.isEmpty {
                var typing = context.typingAttributes
                let outdented = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                outdented.textLists.removeLast()
                if outdented.textLists.isEmpty {
                    typing.removeValue(forKey: MDAttr.listItemStart)
                    typing.removeValue(forKey: MDAttr.checkbox)
                }
                typing[.paragraphStyle] = outdented
                return Result(selection: context.selection, typingAttributes: typing, mutated: false)
            }
            return nil
        }

        beginMutation("Outdent", in: context)
        storage.beginEditing()
        for range in listParagraphs {
            guard let style = mutableParagraphStyle(at: range.location, in: storage),
                  !style.textLists.isEmpty else { continue }
            style.textLists.removeLast()
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            if style.textLists.isEmpty {
                storage.removeAttribute(MDAttr.listItemStart, range: range)
                storage.removeAttribute(MDAttr.checkbox, range: range)
            }
        }
        storage.endEditing()
        StyleEngine.style(storage, range: context.selection)
        return Result(selection: context.selection, typingAttributes: nil, mutated: true)
    }

    // MARK: - Backspace

    /// Backspace at the very start of a styled paragraph (heading, quote,
    /// code block, list item) clears the style to body without deleting text
    /// — the second press then merges with the previous paragraph as usual
    /// (Word behavior). Backspace at the start of a paragraph following a
    /// horizontal rule deletes the rule instead of merging into it. Backspace
    /// at the start of a table cell — or at the start of the paragraph
    /// directly after a table — is swallowed: merging across a cell boundary
    /// would corrupt the table's block structure.
    static func deleteBackward(in context: Context) -> Result? {
        let storage = context.storage
        guard context.selection.length == 0, storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        let paragraph = paragraph(at: cursor, in: context)
        guard cursor == paragraph.content.location else { return nil }

        // Backspace at the start of a table cell is swallowed (Word
        // behavior): deleting the separating newline would merge two cells
        // into one paragraph and corrupt the table's block structure.
        if paragraph.isTableCell {
            return Result(selection: context.selection, typingAttributes: nil, mutated: false)
        }

        // Cursor directly before a horizontal rule: delete the rule paragraph
        // (merging would glue it onto the previous paragraph and swallow it).
        if paragraph.isThematicBreak {
            beginMutation("Delete Horizontal Rule", in: context)
            var range = paragraph.range
            if range.length == paragraph.content.length, range.location > 0 {
                // Last paragraph without a trailing newline: take the
                // preceding separator along.
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            storage.deleteCharacters(in: range)
            return Result(
                selection: NSRange(location: range.location, length: 0),
                typingAttributes: bodyTypingAttributes(),
                mutated: true
            )
        }

        if cursor > 0 {
            let previous = EditingBehavior.paragraph(at: cursor - 1, in: context)
            // Backspace at the start of the paragraph directly after a
            // table would merge body text into the last cell; swallow it.
            if previous.isTableCell {
                return Result(selection: context.selection, typingAttributes: nil, mutated: false)
            }
            // Backspace at the start of the paragraph after a rule deletes
            // the rule (Word behavior), not the paragraph break.
            if previous.isThematicBreak {
                beginMutation("Delete Horizontal Rule", in: context)
                storage.deleteCharacters(in: previous.range)
                return Result(
                    selection: NSRange(location: previous.range.location, length: 0),
                    typingAttributes: bodyTypingAttributes(),
                    mutated: true
                )
            }
            // Merging text into a raw block would make it invisible to the
            // serializer (raw blocks re-emit their stored source), so the
            // keystroke is swallowed instead of corrupting the save.
            if previous.isRawBlock {
                return Result(selection: context.selection, typingAttributes: nil, mutated: false)
            }
        }

        let styled = paragraph.headingLevel != nil || paragraph.quoteDepth > 0
            || paragraph.codeBlock != nil || !paragraph.textLists.isEmpty
        guard styled else { return nil }
        // (Raw blocks are deliberately not cleared here: that would surface
        // their stored source as editable text, which save would escape.)

        var mutated = false
        if paragraph.range.length > 0 {
            beginMutation("Clear Formatting", in: context)
            storage.beginEditing()
            storage.removeAttribute(MDAttr.headingLevel, range: paragraph.range)
            storage.removeAttribute(MDAttr.blockQuoteDepth, range: paragraph.range)
            storage.removeAttribute(MDAttr.codeBlock, range: paragraph.range)
            if let style = mutableParagraphStyle(at: paragraph.range.location, in: storage), !style.textLists.isEmpty {
                style.textLists = []
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            }
            storage.removeAttribute(MDAttr.listItemStart, range: paragraph.range)
            storage.removeAttribute(MDAttr.checkbox, range: paragraph.range)
            storage.endEditing()
            StyleEngine.style(storage, range: paragraph.range)
            mutated = true
        }
        return Result(selection: context.selection, typingAttributes: bodyTypingAttributes(), mutated: mutated)
    }

    // MARK: - Forward delete

    /// Forward delete at the end of a table cell's content — or at the end of
    /// the paragraph directly before a table — is swallowed (the mirror of
    /// Backspace at a cell start). Everything else falls through to the
    /// default character deletion.
    static func deleteForward(in context: Context) -> Result? {
        let storage = context.storage
        guard context.selection.length == 0, storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        let paragraph = paragraph(at: cursor, in: context)
        if paragraph.isTableCell, cursor >= NSMaxRange(paragraph.content) {
            return Result(selection: context.selection, typingAttributes: nil, mutated: false)
        }
        if !paragraph.isTableCell, cursor == NSMaxRange(paragraph.content), cursor < storage.length {
            let next = EditingBehavior.paragraph(at: cursor + 1, in: context)
            if next.isTableCell {
                return Result(selection: context.selection, typingAttributes: nil, mutated: false)
            }
        }
        return nil
    }

    // MARK: - Paragraph model

    /// The paragraph facts the decisions are based on.
    private struct Paragraph {
        /// Full range including the terminating newline.
        var range: NSRange
        /// Range without the terminating newline (may be empty).
        var content: NSRange
        /// Attributes read at the paragraph start; for a trailing empty
        /// paragraph (no characters) the typing attributes stand in.
        var attributes: [NSAttributedString.Key: Any]

        var textLists: [NSTextList] { (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? [] }
        var headingLevel: Int? { attributes[MDAttr.headingLevel] as? Int }
        var quoteDepth: Int { attributes[MDAttr.blockQuoteDepth] as? Int ?? 0 }
        var codeBlock: String? { attributes[MDAttr.codeBlock] as? String }
        var isRawBlock: Bool { attributes[MDAttr.rawBlock] != nil }
        var isThematicBreak: Bool { attributes[MDAttr.thematicBreak] as? Bool ?? false }
        var isTableCell: Bool { !((attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty ?? true) }
        var hasCheckbox: Bool { attributes[MDAttr.checkbox] != nil }
    }

    /// The `\n`-delimited paragraph containing `location`, with its semantics.
    private static func paragraph(at location: Int, in context: Context) -> Paragraph {
        let storage = context.storage
        let string = storage.string as NSString
        let range = storage.mdParagraphRange(for: NSRange(location: location, length: 0))
        var content = range
        if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A {
            content.length -= 1
        }
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = context.typingAttributes
        }
        return Paragraph(range: range, content: content, attributes: attributes)
    }

    // MARK: - Helpers

    /// Registers the pre-mutation snapshot as one undo step.
    private static func beginMutation(_ actionName: String, in context: Context) {
        EditorUndo.registerUndo(
            storage: context.storage,
            selection: context.selection,
            undoManager: context.undoManager,
            actionName: actionName,
            restoreSelection: context.restoreSelection
        )
    }

    /// Body-text typing attributes, optionally inside a block quote.
    static func bodyTypingAttributes(quoteDepth: Int = 0) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: StyleEngine.bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        if quoteDepth > 0 {
            attributes[MDAttr.blockQuoteDepth] = quoteDepth
        }
        return attributes
    }

    /// Attributes for an inserted character: what the user would have typed
    /// with — the attributes before the cursor (or after, at document start).
    static func attributesForInsertion(at location: Int, in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        guard storage.length > 0 else { return bodyTypingAttributes() }
        let index = location > 0 ? location - 1 : 0
        return storage.attributes(at: min(index, storage.length - 1), effectiveRange: nil)
    }

    /// Typing attributes for the paragraph following a freshly inserted
    /// break: the tail's own first character when there is one, so structural
    /// attributes (list, quote) survive typing at the paragraph start.
    private static func typingAttributesAfterBreak(
        at tailStart: Int,
        fallbackCursor: Int,
        in storage: NSTextStorage
    ) -> [NSAttributedString.Key: Any] {
        if tailStart < storage.length {
            return typingAttributes(from: storage.attributes(at: tailStart, effectiveRange: nil))
        }
        return typingAttributes(from: attributesForInsertion(at: fallbackCursor, in: storage))
    }

    /// Copies attributes for use as typing attributes, stripping the ones
    /// that must not bleed into fresh text (attachments, links).
    private static func typingAttributes(from attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result.removeValue(forKey: .attachment)
        result.removeValue(forKey: .link)
        result.removeValue(forKey: MDAttr.linkTitle)
        return result
    }

    /// Mutable copy of the paragraph style at `location`.
    private static func mutableParagraphStyle(at location: Int, in storage: NSTextStorage) -> NSMutableParagraphStyle? {
        (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle
    }

    /// Range covering the paragraphs around an inserted break (for restyling).
    private static func twoParagraphRange(around location: Int, in storage: NSTextStorage) -> NSRange {
        let start = max(location - 1, 0)
        return NSRange(location: start, length: min(location + 2, storage.length) - start)
    }
}
