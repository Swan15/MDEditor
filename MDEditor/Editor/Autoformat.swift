import AppKit

/// Word-style autoformat-as-you-type.
///
/// A Markdown trigger typed as the *entire* content of a plain body
/// paragraph, followed by Space, converts the paragraph instead of inserting
/// the trigger text: `#`…`######` → heading 1–6, `-`/`*` → bullet list,
/// `N.` → ordered list starting at N, `>` → block quote, three backticks →
/// code block, and `---` (including its smart-dash forms) → a thematic break
/// replacing the paragraph.
///
/// The transform runs headless on the storage + selection, exactly like
/// `EditingBehavior`; the view layer applies the returned selection and
/// typing attributes and swallows the Space. Requiring the trigger to be the
/// paragraph's whole content keeps the conversion unambiguous: clicking into
/// existing text can never trigger it, and the trigger characters are simply
/// replaced by the formatting. The semantic attributes applied are exactly
/// the ones the builder produces for the equivalent Markdown, so saving
/// stays canonical.
enum Autoformat {
    /// Attempts the transform for a just-typed character. Returns nil when
    /// the keystroke should be inserted normally: no trigger at the caret,
    /// a styled context (heading/quote/list/code/raw/table/rule), or the
    /// preference off.
    static func transform(
        typedCharacter: String,
        enabled: Bool,
        in context: EditingBehavior.Context
    ) -> EditingBehavior.Result? {
        guard enabled, typedCharacter == " ", context.selection.length == 0 else { return nil }
        let storage = context.storage
        guard storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        let paragraph = storage.mdParagraphRange(for: NSRange(location: cursor, length: 0))
        guard paragraph.location < storage.length else { return nil }
        let string = storage.string as NSString
        var content = paragraph
        if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A {
            content.length -= 1
        }
        // The caret must sit at the end of the paragraph's content, and the
        // whole content must be a trigger.
        guard content.length > 0, NSMaxRange(content) == cursor,
              let trigger = Trigger(string.substring(with: content)) else { return nil }
        // Only plain body paragraphs convert.
        guard isPlainBody(storage.attributes(at: paragraph.location, effectiveRange: nil)) else { return nil }

        EditorUndo.registerUndo(
            storage: storage,
            selection: context.selection,
            undoManager: context.undoManager,
            actionName: trigger.undoActionName,
            restoreSelection: context.restoreSelection
        )
        return trigger.apply(to: storage, paragraph: paragraph, content: content)
    }

    /// True when the paragraph carries no block-level semantics.
    private static func isPlainBody(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        if attributes[MDAttr.headingLevel] != nil { return false }
        if attributes[MDAttr.blockQuoteDepth] != nil { return false }
        if attributes[MDAttr.codeBlock] != nil { return false }
        if attributes[MDAttr.rawBlock] != nil { return false }
        if attributes[MDAttr.thematicBreak] != nil { return false }
        if attributes[MDAttr.inlineCode] as? Bool == true { return false }
        guard let style = attributes[.paragraphStyle] as? NSParagraphStyle else { return true }
        return style.textLists.isEmpty && style.textBlocks.isEmpty
    }

    // MARK: - Triggers

    /// A recognized paragraph-start trigger.
    private enum Trigger {
        case heading(Int)
        case bullet
        case ordered(Int)
        case quote
        case codeBlock
        case thematicBreak

        /// Parses the paragraph content into a trigger, or nil.
        init?(_ text: String) {
            switch text {
            case ">": self = .quote
            case "-", "*": self = .bullet
            case "```": self = .codeBlock
            default:
                if text.allSatisfy({ $0 == "#" }), (1...6).contains(text.count) {
                    self = .heading(text.count)
                } else if let start = Self.orderedStart(text) {
                    self = .ordered(start)
                } else if Self.isDashRun(text) {
                    self = .thematicBreak
                } else {
                    return nil
                }
            }
        }

        /// `N.` with the GFM limit of nine digits; N is the list start.
        private static func orderedStart(_ text: String) -> Int? {
            let digits = text.dropLast()
            guard text.hasSuffix("."), !digits.isEmpty, digits.count <= 9,
                  digits.allSatisfy({ $0.isNumber }), let start = Int(digits), start >= 1 else { return nil }
            return start
        }

        /// Three or more hyphens, tolerant of smart-dash substitution: with
        /// it on, typing `--` produces an em dash, so the stored text of a
        /// typed `---` is often `—-` (an em dash counts as two hyphens).
        private static func isDashRun(_ text: String) -> Bool {
            var hyphens = 0
            for character in text {
                switch character {
                case "-": hyphens += 1
                case "\u{2013}": hyphens += 1 // en dash
                case "\u{2014}": hyphens += 2 // em dash
                default: return false
                }
            }
            return hyphens >= 3
        }

        var undoActionName: String {
            switch self {
            case .heading: return "Heading"
            case .bullet: return "Bullet List"
            case .ordered: return "Ordered List"
            case .quote: return "Block Quote"
            case .codeBlock: return "Code Block"
            case .thematicBreak: return "Horizontal Rule"
            }
        }

        /// Performs the conversion. The trigger characters are removed and
        /// the (now empty) paragraph receives the block's semantic attribute;
        /// the same attribute goes into the returned typing attributes so the
        /// text about to be typed carries it too (the trailing-empty-paragraph
        /// case, mirroring `FormatCommands`' empty-document priming).
        func apply(to storage: NSTextStorage, paragraph: NSRange, content: NSRange) -> EditingBehavior.Result {
            switch self {
            case .thematicBreak:
                return applyThematicBreak(to: storage, paragraph: paragraph, content: content)
            case .heading, .bullet, .ordered, .quote, .codeBlock:
                break
            }

            storage.replaceCharacters(in: content, with: "")
            let remaining = NSRange(location: paragraph.location, length: paragraph.length - content.length)
            var typing = EditingBehavior.bodyTypingAttributes()
            switch self {
            case .heading(let level):
                typing[MDAttr.headingLevel] = level
                if remaining.length > 0 {
                    storage.addAttribute(MDAttr.headingLevel, value: level, range: remaining)
                }
            case .quote:
                typing[MDAttr.blockQuoteDepth] = 1
                if remaining.length > 0 {
                    storage.addAttribute(MDAttr.blockQuoteDepth, value: 1, range: remaining)
                }
            case .codeBlock:
                typing[MDAttr.codeBlock] = ""
                typing[.font] = StyleEngine.codeFont
                if remaining.length > 0 {
                    storage.addAttribute(MDAttr.codeBlock, value: "", range: remaining)
                }
            case .bullet, .ordered:
                let list: NSTextList
                switch self {
                case .bullet:
                    list = NSTextList(markerFormat: .disc, options: 0)
                case .ordered(let start):
                    list = NSTextList(markerFormat: .decimal, options: 0)
                    list.startingItemNumber = start
                default:
                    preconditionFailure("unreachable")
                }
                let style = NSMutableParagraphStyle()
                style.textLists = [list]
                typing[.paragraphStyle] = style
                typing[MDAttr.listItemStart] = true
                if remaining.length > 0 {
                    // A separate instance: paragraph styles are shared by
                    // reference and the typing copy must stay independent.
                    storage.addAttribute(.paragraphStyle, value: style.copy(), range: remaining)
                    storage.addAttribute(MDAttr.listItemStart, value: true, range: remaining)
                }
            case .thematicBreak:
                preconditionFailure("handled above")
            }
            if storage.length > 0, remaining.length > 0 {
                StyleEngine.style(storage, range: remaining)
            }
            return EditingBehavior.Result(
                selection: NSRange(location: paragraph.location, length: 0),
                typingAttributes: typing,
                mutated: true
            )
        }

        /// The trigger paragraph becomes the rule itself (placeholder NBSP +
        /// marker; the style pass swaps in the full-width attachment). The
        /// caret lands in the paragraph after the rule — appended when the
        /// rule ends the document.
        private func applyThematicBreak(
            to storage: NSTextStorage,
            paragraph: NSRange,
            content: NSRange
        ) -> EditingBehavior.Result {
            let rule = NSAttributedString(string: "\u{00A0}", attributes: [
                .font: StyleEngine.bodyFont,
                MDAttr.thematicBreak: true
            ])
            storage.replaceCharacters(in: content, with: rule)
            let hasTrailingNewline = paragraph.length > content.length
            if !hasTrailingNewline {
                storage.insert(
                    NSAttributedString(string: "\n", attributes: EditingBehavior.bodyTypingAttributes()),
                    at: paragraph.location + 1
                )
            }
            let ruleEnd = NSMaxRange(storage.mdParagraphRange(for: NSRange(location: paragraph.location, length: 0)))
            StyleEngine.style(storage, range: NSRange(location: paragraph.location, length: min(2, storage.length - paragraph.location)))
            return EditingBehavior.Result(
                selection: NSRange(location: ruleEnd, length: 0),
                typingAttributes: EditingBehavior.bodyTypingAttributes(),
                mutated: true
            )
        }
    }
}
