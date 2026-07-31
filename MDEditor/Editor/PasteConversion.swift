import AppKit

/// Plain-text paste conversion: text that already looks like Markdown is
/// parsed and inserted as styled content instead of raw syntax.
///
/// Conservative by design: any rich pasteboard flavor (RTF, HTML, images,
/// files) or any doubt about the text means "paste as-is".
enum PasteConversion {
    /// Rich flavors whose presence means the paste is not plain text.
    private static let richFlavors: [NSPasteboard.PasteboardType] = [
        .rtf, .rtfd, .html, .pdf, .png, .tiff, .fileURL, .URL
    ]

    /// Plain-text pasteboard content worth converting, or nil when the paste
    /// should go through the default path (rich flavors present, no string,
    /// or the text doesn't look like Markdown).
    static func markdownToConvert(from pasteboard: NSPasteboard) -> String? {
        guard pasteboard.availableType(from: richFlavors) == nil,
              let text = pasteboard.string(forType: .string),
              shouldConvertPlainText(text) else { return nil }
        return text
    }

    /// True when plain text contains at least one Markdown construct worth
    /// converting (heading, list, quote, fence, rule, table delimiter, or
    /// inline emphasis/code/strikethrough/link).
    static func shouldConvertPlainText(_ text: String) -> Bool {
        let patterns = [
            "(^|\n) {0,3}#{1,6}([ \t]|$)",                           // ATX heading
            "(^|\n) {0,3}(```|~~~)",                                  // fenced code block
            "(^|\n) {0,3}>([ \t]|$)",                                 // block quote
            "(^|\n) {0,3}([-+*]|[0-9]{1,9}[.)])[ \t]+[^ \t\n]",       // list item with content
            "(^|\n) {0,3}((\\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})[ \t]*(\n|$)", // thematic break
            "(^|\n)[ \t]*\\|?[ \t]*:?-+:?[ \t]*(\\|[ \t]*:?-+:?[ \t]*)+\\|?[ \t]*(\n|$)", // table delimiter row
            "!?\\[[^\\]\n]+\\]\\([^)\n]+\\)",                         // link or image
            "`[^`\n]+`",                                              // inline code
            "\\*\\*[^*\n]+\\*\\*",                                     // bold
            "__[^_\n]+__",
            "~~[^~\n]+~~",                                            // strikethrough
            "(?<![A-Za-z0-9*])\\*[^* \t\n][^*\n]*\\*(?![A-Za-z0-9*])",  // *emphasis*
            "(?<![A-Za-z0-9_])_[^_ \t\n][^_\n]*_(?![A-Za-z0-9_])",      // _emphasis_
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Inserts Markdown source at the selection as styled content (parse →
    /// build). Returns the cursor position after the inserted content.
    ///
    /// Block semantics are read at paragraph starts, so a mid-paragraph
    /// insertion first splits the paragraph; pasting at the start of a
    /// non-empty paragraph pushes that paragraph below the pasted blocks.
    @discardableResult
    static func insert(markdown: String, storage: NSTextStorage, selection: NSRange) -> Int {
        if selection.length > 0 {
            storage.replaceCharacters(in: selection, with: "")
        }
        let converted = AttributedStringBuilder.build(MarkdownParser.parse(markdown))
        let insertion = min(selection.location, storage.length)
        guard converted.length > 0 else { return insertion }

        var insertionPoint = insertion
        var needsTrailingBreak = false
        if storage.length > 0 {
            let paragraph = storage.mdParagraphRange(for: NSRange(location: insertionPoint, length: 0))
            if insertionPoint > paragraph.location {
                // Mid-paragraph: split so the pasted content starts a
                // paragraph of its own (block attributes must land at a
                // paragraph start or they'd be silently dropped).
                let attributes = EditingBehavior.attributesForInsertion(at: insertionPoint, in: storage)
                storage.insert(NSAttributedString(string: "\n", attributes: attributes), at: insertionPoint)
                insertionPoint += 1
            } else if contentLength(of: paragraph, in: storage) > 0 {
                // Start of a non-empty paragraph: push it below the paste.
                needsTrailingBreak = true
            }
        }
        storage.insert(converted, at: insertionPoint)
        if needsTrailingBreak {
            let attributes = EditingBehavior.attributesForInsertion(at: insertionPoint + converted.length, in: storage)
            storage.insert(NSAttributedString(string: "\n", attributes: attributes), at: insertionPoint + converted.length)
        }
        StyleEngine.style(storage, range: NSRange(
            location: max(insertionPoint - 1, 0),
            length: min(converted.length + 2, storage.length - max(insertionPoint - 1, 0))
        ))
        return insertionPoint + converted.length
    }

    /// Length of a paragraph's content (range minus its terminating newline).
    private static func contentLength(of paragraph: NSRange, in storage: NSTextStorage) -> Int {
        guard paragraph.length > 0 else { return 0 }
        let string = storage.string as NSString
        let endsWithNewline = string.character(at: NSMaxRange(paragraph) - 1) == 0x0A
        return paragraph.length - (endsWithNewline ? 1 : 0)
    }
}
