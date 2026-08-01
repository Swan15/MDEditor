import AppKit
import QuickLookThumbnailing

/// Renders Finder thumbnails for Markdown files: the first screenful of the
/// document, styled, so the file icon shows part of the actual content.
/// Any failure answers nil so Finder falls back to the generic icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        guard let markdown = Self.readMarkdown(from: request.fileURL) else {
            handler(nil, nil)
            return
        }
        // Render at pixel resolution (points × scale) for a crisp reply.
        let pixelSize = CGSize(
            width: request.maximumSize.width * request.scale,
            height: request.maximumSize.height * request.scale
        )
        // Fonts and drawing are main-thread AppKit territory; thumbnail
        // requests arrive on a background queue.
        let image: NSImage?
        if Thread.isMainThread {
            image = MarkdownThumbnailImage.render(markdown: markdown, size: pixelSize)
        } else {
            image = DispatchQueue.main.sync {
                MarkdownThumbnailImage.render(markdown: markdown, size: pixelSize)
            }
        }
        guard let image else {
            handler(nil, nil)
            return
        }
        let contextSize = request.maximumSize
        handler(QLThumbnailReply(contextSize: contextSize, currentContextDrawing: {
            image.draw(in: CGRect(origin: .zero, size: contextSize))
            return true
        }), nil)
    }

    /// Reads the Markdown source, capped so huge files stay fast. Quick Look
    /// grants the sandboxed extension access to the requested file.
    private static func readMarkdown(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: MarkdownThumbnailImage.maximumSourceLength) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
