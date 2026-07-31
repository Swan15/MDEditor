import AppKit

/// Formatting operations on the live text storage.
///
/// Every command takes an `NSTextStorage` plus a selection, so it runs
/// headless in tests as well as against the editor's text view. Commands only
/// change *semantic* attributes (plus the fonts carrying bold/italic) and
/// finish by re-styling the affected paragraphs with `StyleEngine`, so the
/// result always round-trips through `MarkdownSerializer`.
enum FormatCommands {
    // MARK: - Bold / italic / strikethrough

    /// Flips the bold trait on the selection. Word semantics: if the whole
    /// selection is already bold, unbold it; otherwise make it all bold.
    static func toggleBold(_ storage: NSTextStorage, selection: NSRange) {
        toggleFontTrait(.bold, mask: .boldFontMask, storage: storage, selection: selection)
    }

    /// Flips the italic trait on the selection (same semantics as bold).
    static func toggleItalic(_ storage: NSTextStorage, selection: NSRange) {
        toggleFontTrait(.italic, mask: .italicFontMask, storage: storage, selection: selection)
    }

    private static func toggleFontTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        mask: NSFontTraitMask,
        storage: NSTextStorage,
        selection: NSRange
    ) {
        guard let selection = clamped(selection, storage: storage), selection.length > 0 else { return }
        let remove = isFontTraitFullyApplied(trait, storage: storage, range: selection)
        var runs: [(NSRange, NSFont?)] = []
        storage.enumerateAttribute(.font, in: selection, options: []) { value, range, _ in
            runs.append((range, value as? NSFont))
        }
        storage.beginEditing()
        for (range, font) in runs {
            let base = font ?? StyleEngine.bodyFont
            let converted = remove
                ? NSFontManager.shared.convert(base, toNotHaveTrait: mask)
                : NSFontManager.shared.convert(base, toHaveTrait: mask)
            storage.addAttribute(.font, value: converted, range: range)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    /// True when every run in `range` holding *visible* characters carries
    /// the given trait. Whitespace-only runs never veto: a line/triple-click
    /// selection includes the paragraph's trailing `\n`, which stays unstyled
    /// — counting it would judge fully styled text "not fully applied" and
    /// the first toggle would invisibly re-apply instead of removing.
    static func isFontTraitFullyApplied(
        _ trait: NSFontDescriptor.SymbolicTraits,
        storage: NSTextStorage,
        range: NSRange
    ) -> Bool {
        guard range.length > 0 else { return false }
        var sawVisible = false
        var fullyApplied = true
        enumerateVisibleRuns(in: storage, range: range, attribute: .font) { runRange in
            sawVisible = true
            let traits = (storage.attribute(.font, at: runRange.location, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits ?? []
            if !traits.contains(trait) {
                fullyApplied = false
            }
            return !fullyApplied
        }
        return sawVisible && fullyApplied
    }

    /// True when every visible run in `range` is struck through (same
    /// whitespace rule as `isFontTraitFullyApplied`).
    static func isStrikethroughFullyApplied(storage: NSTextStorage, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var sawVisible = false
        var fullyApplied = true
        enumerateVisibleRuns(in: storage, range: range, attribute: .strikethroughStyle) { runRange in
            sawVisible = true
            let struck = (storage.attribute(.strikethroughStyle, at: runRange.location, effectiveRange: nil) as? Int ?? 0) != 0
            if !struck {
                fullyApplied = false
            }
            return !fullyApplied
        }
        return sawVisible && fullyApplied
    }

    /// Calls `body` with the range of every run of `key` in `range` that
    /// contains at least one non-whitespace character; returning true from
    /// `body` stops the enumeration.
    private static func enumerateVisibleRuns(
        in storage: NSTextStorage,
        range: NSRange,
        attribute key: NSAttributedString.Key,
        using body: (NSRange) -> Bool
    ) {
        let string = storage.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        let end = NSMaxRange(range)
        while start < end {
            var effective = NSRange()
            _ = storage.attribute(key, at: start, longestEffectiveRange: &effective, in: range)
            let text = string.substring(with: effective)
            if !text.isEmpty, text.rangeOfCharacter(from: whitespace.inverted) != nil {
                if body(effective) { return }
            }
            start = NSMaxRange(effective)
        }
    }

    /// Flips `.strikethroughStyle` on the selection (all-or-nothing).
    static func toggleStrikethrough(_ storage: NSTextStorage, selection: NSRange) {
        guard let selection = clamped(selection, storage: storage), selection.length > 0 else { return }
        let fullyApplied = isStrikethroughFullyApplied(storage: storage, range: selection)
        storage.beginEditing()
        if fullyApplied {
            storage.removeAttribute(.strikethroughStyle, range: selection)
        } else {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    // MARK: - Headings

    /// Makes the selected paragraphs headings of `level` (1–6), clearing any
    /// conflicting structure (code block, raw block, list).
    static func applyHeading(level: Int, storage: NSTextStorage, selection: NSRange) {
        guard (1...6).contains(level), let selection = clamped(selection, storage: storage) else { return }
        storage.beginEditing()
        for paragraph in storage.mdParagraphRanges(in: selection) {
            storage.addAttribute(MDAttr.headingLevel, value: level, range: paragraph)
            storage.removeAttribute(MDAttr.codeBlock, range: paragraph)
            storage.removeAttribute(MDAttr.rawBlock, range: paragraph)
            removeListFormatting(storage, range: paragraph)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    /// Returns the selected paragraphs to plain body text.
    static func applyBody(storage: NSTextStorage, selection: NSRange) {
        guard let selection = clamped(selection, storage: storage) else { return }
        storage.beginEditing()
        for paragraph in storage.mdParagraphRanges(in: selection) {
            storage.removeAttribute(MDAttr.headingLevel, range: paragraph)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    // MARK: - Lists

    /// Wraps the selected paragraphs in a bullet/ordered list, or unwraps
    /// them when every paragraph is already an item of that list type. A list
    /// of the other type is converted in place.
    static func toggleList(ordered: Bool, storage: NSTextStorage, selection: NSRange) {
        guard let selection = clamped(selection, storage: storage) else { return }
        let paragraphs = storage.mdParagraphRanges(in: selection)
        guard !paragraphs.isEmpty else { return }
        let format: NSTextList.MarkerFormat = ordered ? .decimal : .disc
        func innermostList(_ paragraph: NSRange) -> NSTextList? {
            (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists.last
        }
        let allMatch = paragraphs.allSatisfy { innermostList($0)?.markerFormat == format }
        storage.beginEditing()
        if allMatch {
            // Unwrap one level; drop item state when the list is gone.
            for paragraph in paragraphs {
                guard let style = mutableParagraphStyle(storage, at: paragraph),
                      !style.textLists.isEmpty else { continue }
                style.textLists.removeLast()
                if style.textLists.isEmpty {
                    storage.removeAttribute(MDAttr.listItemStart, range: paragraph)
                    storage.removeAttribute(MDAttr.checkbox, range: paragraph)
                }
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        } else {
            // One shared list object: items with the same list identity
            // serialize as a single tight list.
            let list = NSTextList(markerFormat: format, options: 0)
            for paragraph in paragraphs {
                let style = mutableParagraphStyle(storage, at: paragraph) ?? NSMutableParagraphStyle()
                if style.textLists.last?.markerFormat == format {
                    // Already the requested type (mixed selection): keep.
                } else if style.textLists.isEmpty {
                    style.textLists = [list]
                } else {
                    style.textLists[style.textLists.count - 1] = list
                }
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                storage.addAttribute(MDAttr.listItemStart, value: true, range: paragraph)
                storage.removeAttribute(MDAttr.headingLevel, range: paragraph)
            }
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    // MARK: - Block quotes

    /// Quotes the selected paragraphs (depth 1), or unquotes them when every
    /// paragraph is already quoted.
    static func toggleBlockQuote(storage: NSTextStorage, selection: NSRange) {
        guard let selection = clamped(selection, storage: storage) else { return }
        let paragraphs = storage.mdParagraphRanges(in: selection)
        guard !paragraphs.isEmpty else { return }
        let allQuoted = paragraphs.allSatisfy {
            storage.attribute(MDAttr.blockQuoteDepth, at: $0.location, effectiveRange: nil) != nil
        }
        storage.beginEditing()
        for paragraph in paragraphs {
            if allQuoted {
                storage.removeAttribute(MDAttr.blockQuoteDepth, range: paragraph)
            } else {
                storage.addAttribute(MDAttr.blockQuoteDepth, value: 1, range: paragraph)
            }
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    // MARK: - Code blocks

    /// Turns the selected paragraphs into a fenced code block ("" language),
    /// or back to body text when they already are one.
    static func toggleCodeBlock(storage: NSTextStorage, selection: NSRange) {
        guard let selection = clamped(selection, storage: storage) else { return }
        let paragraphs = storage.mdParagraphRanges(in: selection)
        guard !paragraphs.isEmpty else { return }
        let allCode = paragraphs.allSatisfy {
            storage.attribute(MDAttr.codeBlock, at: $0.location, effectiveRange: nil) != nil
        }
        storage.beginEditing()
        for paragraph in paragraphs {
            if allCode {
                storage.removeAttribute(MDAttr.codeBlock, range: paragraph)
            } else {
                storage.addAttribute(MDAttr.codeBlock, value: "", range: paragraph)
                storage.removeAttribute(MDAttr.headingLevel, range: paragraph)
                storage.removeAttribute(MDAttr.rawBlock, range: paragraph)
                removeListFormatting(storage, range: paragraph)
            }
        }
        storage.endEditing()
        StyleEngine.style(storage, range: selection)
    }

    /// Drops list formatting (markers, item-start and checkbox state).
    private static func removeListFormatting(_ storage: NSTextStorage, range: NSRange) {
        guard let style = mutableParagraphStyle(storage, at: range), !style.textLists.isEmpty else { return }
        style.textLists = []
        storage.addAttribute(.paragraphStyle, value: style, range: range)
        storage.removeAttribute(MDAttr.listItemStart, range: range)
        storage.removeAttribute(MDAttr.checkbox, range: range)
    }

    /// Mutable copy of the paragraph style at the start of `range`.
    private static func mutableParagraphStyle(_ storage: NSTextStorage, at range: NSRange) -> NSMutableParagraphStyle? {
        (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle
    }

    // MARK: - Links

    /// Sets a link on the selected text, or inserts link text at the
    /// insertion point. `text` (the dialog's Text field) replaces the
    /// selected text when it differs, and supplies the inserted text when
    /// nothing is selected (falling back to a "link text" placeholder).
    /// A nil `title` clears any existing link title. Returns the range to
    /// select afterwards.
    @discardableResult
    static func insertLink(
        text: String? = nil,
        url: String,
        title: String?,
        storage: NSTextStorage,
        selection: NSRange
    ) -> NSRange {
        let selection = clamped(selection, storage: storage) ?? NSRange(location: 0, length: 0)
        guard selection.location <= storage.length else { return selection }
        // Match the builder: keep the destination byte-for-byte — a URL value
        // only when it round-trips exactly, otherwise the raw string.
        let linkValue: Any = if let parsed = URL(string: url), parsed.absoluteString == url {
            parsed
        } else {
            url as NSString
        }
        let replacement = (text?.isEmpty == false) ? text : nil
        storage.beginEditing()
        var result = selection
        if selection.length > 0 {
            if let replacement, (storage.string as NSString).substring(with: selection) != replacement {
                // The dialog edited the link text: swap it in, keeping the
                // run's style (never an attachment — the text replaces it).
                var attributes = storage.attributes(at: selection.location, effectiveRange: nil)
                attributes.removeValue(forKey: .attachment)
                attributes[.link] = linkValue
                if let title {
                    attributes[MDAttr.linkTitle] = title
                } else {
                    attributes.removeValue(forKey: MDAttr.linkTitle)
                }
                storage.replaceCharacters(
                    in: selection,
                    with: NSAttributedString(string: replacement, attributes: attributes)
                )
                result = NSRange(location: selection.location, length: (replacement as NSString).length)
            } else {
                storage.addAttribute(.link, value: linkValue, range: selection)
                if let title {
                    storage.addAttribute(MDAttr.linkTitle, value: title, range: selection)
                } else {
                    storage.removeAttribute(MDAttr.linkTitle, range: selection)
                }
            }
        } else {
            var attributes: [NSAttributedString.Key: Any] = [.font: StyleEngine.bodyFont, .link: linkValue]
            if let title {
                attributes[MDAttr.linkTitle] = title
            }
            let placeholder = NSAttributedString(string: replacement ?? "link text", attributes: attributes)
            storage.insert(placeholder, at: selection.location)
            result = NSRange(location: selection.location, length: placeholder.length)
        }
        storage.endEditing()
        StyleEngine.style(storage, range: result)
        return result
    }

    // MARK: - Thematic break

    /// Inserts a horizontal rule after the paragraph containing the selection.
    /// Returns the cursor position (start of the paragraph after the rule).
    @discardableResult
    static func insertThematicBreak(storage: NSTextStorage, selection: NSRange) -> Int {
        let string = storage.string as NSString
        var cursor: Int
        storage.beginEditing()
        if storage.length == 0 {
            storage.insert(NSAttributedString(string: "\u{00A0}\n", attributes: ruleAttributes), at: 0)
            cursor = 2
        } else {
            let anchor = min(max(selection.location, 0), storage.length - 1)
            let paragraph = storage.mdParagraphRange(for: NSRange(location: anchor, length: 0))
            var contentEnd = NSMaxRange(paragraph)
            let hasTrailingNewline = string.character(at: contentEnd - 1) == 0x0A
            if hasTrailingNewline { contentEnd -= 1 }
            // Separator ending the current paragraph, blended with its attrs
            // (paragraph semantics are read at the paragraph start, so an
            // inherited attribute on the newline itself is harmless).
            let previousAttributes: [NSAttributedString.Key: Any] = contentEnd > 0
                ? storage.attributes(at: contentEnd - 1, effectiveRange: nil)
                : [.font: StyleEngine.bodyFont]
            storage.insert(NSAttributedString(string: "\n", attributes: previousAttributes), at: contentEnd)
            storage.insert(NSAttributedString(string: "\u{00A0}", attributes: ruleAttributes), at: contentEnd + 1)
            if !hasTrailingNewline {
                storage.insert(NSAttributedString(string: "\n", attributes: ruleAttributes), at: contentEnd + 2)
            }
            cursor = contentEnd + 3
        }
        storage.endEditing()
        StyleEngine.style(storage, range: NSRange(location: max(cursor - 3, 0), length: min(3, storage.length)))
        return cursor
    }

    /// Attributes of a thematic-break paragraph (placeholder NBSP + marker).
    private static var ruleAttributes: [NSAttributedString.Key: Any] {
        [.font: StyleEngine.bodyFont, MDAttr.thematicBreak: true]
    }

    // MARK: - State inspection

    /// Formatting state at the selection, for toolbar/menu highlighting.
    static func inspect(_ storage: NSTextStorage, selection: NSRange) -> SelectionFormatState {
        var state = SelectionFormatState()
        guard let selection = clamped(selection, storage: storage) else { return state }

        if selection.length > 0 {
            state.isBold = isFontTraitFullyApplied(.bold, storage: storage, range: selection)
            state.isItalic = isFontTraitFullyApplied(.italic, storage: storage, range: selection)
            state.isStrikethrough = isStrikethroughFullyApplied(storage: storage, range: selection)
        } else {
            let index = min(selection.location, storage.length - 1)
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            state.isBold = traits.contains(.bold)
            state.isItalic = traits.contains(.italic)
            state.isStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        }

        let paragraphs = storage.mdParagraphRanges(in: selection)
        var headingLevel: Int?
        var isFirstParagraph = true
        var allOrdered = !paragraphs.isEmpty
        var allBulleted = !paragraphs.isEmpty
        var allQuoted = !paragraphs.isEmpty
        var allCode = !paragraphs.isEmpty
        for paragraph in paragraphs {
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let level = attributes[MDAttr.headingLevel] as? Int
            if isFirstParagraph {
                headingLevel = level
                // Menu validation for table row/column commands keys off the
                // paragraph at the selection start.
                state.isInTable = !((attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
                isFirstParagraph = false
            } else if headingLevel != level {
                headingLevel = nil
            }
            let format = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.last?.markerFormat
            allOrdered = allOrdered && format == .decimal
            allBulleted = allBulleted && format == .disc
            allQuoted = allQuoted && attributes[MDAttr.blockQuoteDepth] != nil
            allCode = allCode && attributes[MDAttr.codeBlock] != nil
        }
        state.headingLevel = headingLevel
        state.isOrderedList = allOrdered
        state.isBulletList = allBulleted
        state.isBlockQuote = allQuoted
        state.isCodeBlock = allCode
        return state
    }

    // MARK: - Helpers

    /// Selection clamped to the storage bounds; nil when the storage is empty.
    private static func clamped(_ range: NSRange, storage: NSTextStorage) -> NSRange? {
        let length = storage.length
        guard length > 0, range.location != NSNotFound, range.location >= 0 else { return nil }
        let location = min(range.location, length)
        let end = min(max(NSMaxRange(range), location), length)
        return NSRange(location: location, length: end - location)
    }
}
