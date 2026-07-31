import AppKit

/// Custom attributed-string keys describing the Markdown semantics of text.
///
/// While a document is open, these attributes — together with the standard
/// `.font`, `.link`, `.strikethroughStyle`, `.attachment` and
/// `.paragraphStyle` (`NSTextList` / `NSTextTableBlock`) attributes — are the
/// source of truth from which Markdown is re-emitted on save.
enum MDAttr {
    /// Int 1–6. Paragraph is an ATX heading of this level.
    static let headingLevel = NSAttributedString.Key("MDHeadingLevel")

    /// Int ≥ 1. Paragraph sits inside this many nested block quotes.
    static let blockQuoteDepth = NSAttributedString.Key("MDBlockQuoteDepth")

    /// String. Paragraph is a fenced code block; the value is the fence's
    /// info string ("" when the fence has no language).
    static let codeBlock = NSAttributedString.Key("MDCodeBlock")

    /// Bool. Run is inline code (emitted surrounded by backticks).
    static let inlineCode = NSAttributedString.Key("MDInlineCode")

    /// Bool. Presence marks a task-list item; value is the checked state.
    static let checkbox = NSAttributedString.Key("MDCheckbox")

    /// Bool. Paragraph starts a new list item (absent/false on the
    /// continuation paragraphs of a multi-paragraph item).
    static let listItemStart = NSAttributedString.Key("MDListItemStart")

    /// String. Title of a link, emitted as `[text](url "title")`.
    static let linkTitle = NSAttributedString.Key("MDLinkTitle")

    /// String. Paragraph is an unsupported construct; the value is the
    /// original Markdown source, re-emitted verbatim on save.
    static let rawBlock = NSAttributedString.Key("MDRawBlock")

    /// Bool. Paragraph is a thematic-break placeholder (emitted as `---`).
    static let thematicBreak = NSAttributedString.Key("MDThematicBreak")

    /// Bool. Table cell paragraph belongs to the header row.
    static let tableHeader = NSAttributedString.Key("MDTableHeader")

    /// [String]. Per-column alignment of a GFM table:
    /// "left", "center", "right" or "" for none.
    static let tableAlignments = NSAttributedString.Key("MDTableAlignments")
}

/// Text attachment for a Markdown image.
///
/// Stores the image source exactly as written plus its alt text; the image
/// data itself is never loaded by the Markdown layer (that is
/// `ImageAttachmentController`'s job, in the Editor layer).
final class MDImageAttachment: NSTextAttachment {
    /// Image path or URL exactly as written in the source.
    var source: String

    /// Plain-text alternative description.
    var altText: String

    /// Optional title, emitted as `![alt](src "title")`.
    var title: String?

    /// Loaded image size in points (nil until the image — or a placeholder —
    /// is loaded). Drives `attachmentBounds`; never serialized.
    var naturalSize: NSSize?

    /// Height cap applied while scaling (set by the controller from the
    /// visible editor height; window-height driven, never serialized).
    var maxDisplayHeight: CGFloat = ImageAttachmentController.defaultMaxDisplayHeight

    /// True while `image` shows a generated placeholder instead of the real
    /// file (missing file, remote URL, …). Placeholders are re-resolved after
    /// a folder grant or a save.
    var isPlaceholder = false

    init(source: String, altText: String, title: String?) {
        self.source = source
        self.altText = altText
        self.title = title
        super.init(data: nil, ofType: nil)
    }

    /// Display bounds: natural size scaled down to the line fragment's width
    /// (never up), then capped at `maxDisplayHeight`, aspect preserved.
    /// Computed per layout pass, so images track the window width like Word
    /// (the layout manager re-queries when the container width changes).
    ///
    /// The fragment's own width is the limit — not the glyph's x position —
    /// so an image that follows text on the same line wraps to a fresh line
    /// at full width instead of being squeezed into the remainder.
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let naturalSize, image != nil else {
            return super.attachmentBounds(
                for: textContainer, proposedLineFragment: lineFrag,
                glyphPosition: position, characterIndex: charIndex
            )
        }
        let size = ImageAttachmentController.displaySize(
            natural: naturalSize, availableWidth: lineFrag.width - 1, maxHeight: maxDisplayHeight
        )
        return CGRect(origin: .zero, size: size)
    }

    required init?(coder: NSCoder) {
        self.source = coder.decodeObject(of: NSString.self, forKey: "source") as String? ?? ""
        self.altText = coder.decodeObject(of: NSString.self, forKey: "altText") as String? ?? ""
        self.title = coder.decodeObject(of: NSString.self, forKey: "title") as String?
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(source as NSString, forKey: "source")
        coder.encode(altText as NSString, forKey: "altText")
        coder.encode(title as NSString?, forKey: "title")
    }
}

/// Fonts used when building attributed strings from Markdown.
enum MDFont {
    static let size = NSFont.systemFontSize

    /// Body font with the given traits applied.
    static func make(bold: Bool = false, italic: Bool = false, monospaced: Bool = false) -> NSFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }
}
