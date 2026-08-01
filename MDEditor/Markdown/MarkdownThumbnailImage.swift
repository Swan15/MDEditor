import AppKit

/// Renders the first screenful of a Markdown document into an image.
///
/// Used by the Quick Look thumbnail extension (Finder icons that show part
/// of the document) and unit-tested through the app target. Pure and
/// view-free: parse → build → draw into an offscreen bitmap.
///
/// AppKit font/drawing calls mean this must run on the main thread (the
/// thumbnail provider hops to it); it is otherwise stateless.
enum MarkdownThumbnailImage {
    /// Cap on parsed source so thumbnail requests stay fast on huge files.
    static let maximumSourceLength = 64 * 1024

    /// Point sizes for heading levels 1–6, matching the editor's proportions.
    private static let headingSizes: [CGFloat] = [26, 22, 18, 16, 14, 13]

    /// Faux-bold heading stroke, as in the editor (never the bold font trait).
    private static let headingStroke: CGFloat = -2.5

    /// A white "page" showing the top of the document: `markdown` parsed and
    /// styled (body/bold/italic/mono fonts from the builder, heading sizes
    /// applied like the editor's), drawn top-left with a comfortable inset
    /// and clipped at the bottom. Nil for blank content or degenerate sizes
    /// so the caller falls back to the generic file icon.
    ///
    /// `size` is the pixel size to render at (pass points × scale).
    static func render(markdown: String, size: CGSize) -> NSImage? {
        guard size.width >= 16, size.height >= 16 else { return nil }
        // Cap parse cost; decoding repairs a mid-character cut.
        let source = markdown.utf8.count <= maximumSourceLength
            ? markdown
            : String(decoding: markdown.utf8.prefix(maximumSourceLength), as: UTF8.self)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let content = NSMutableAttributedString(
            attributedString: AttributedStringBuilder.build(MarkdownParser.parse(source))
        )
        guard content.length > 0 else { return nil }
        styleHeadings(content)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let inset = max(2, (size.width * 0.08).rounded())
        let textRect = NSRect(
            x: inset, y: inset,
            width: size.width - inset * 2, height: size.height - inset * 2
        )
        content.draw(with: textRect, options: .usesLineFragmentOrigin)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Gives heading paragraphs their display look (larger, faux-bold) — the
    /// builder keeps heading styling semantic-only (`MDAttr.headingLevel`),
    /// so thumbnails apply the visual pass the editor's StyleEngine would.
    private static func styleHeadings(_ content: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: content.length)
        content.enumerateAttribute(MDAttr.headingLevel, in: fullRange) { value, range, _ in
            guard let level = value as? Int else { return }
            let size = headingSizes[min(max(level, 1), 6) - 1]
            content.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: range)
            content.addAttribute(.strokeWidth, value: headingStroke, range: range)
        }
    }
}
