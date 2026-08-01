import AppKit

/// Display-size math for Markdown image attachments.
///
/// Lives in the Markdown layer (not the Editor layer's
/// `ImageAttachmentController`) because `MDImageAttachment.attachmentBounds`
/// — compiled everywhere the Markdown sources are, including the Quick Look
/// thumbnail extension — needs it to size images during layout.
enum MDImageDisplay {
    /// Fallback height cap before the editor reports its real visible height.
    static let defaultMaxDisplayHeight: CGFloat = 640

    /// Display size for an image: natural width scaled DOWN to the available
    /// text width (never up), then capped at `maxHeight`, aspect preserved.
    static func displaySize(natural: NSSize, availableWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        guard natural.width > 0, natural.height > 0 else {
            return NSSize(width: max(availableWidth, 1), height: 1)
        }
        var width = min(natural.width, max(availableWidth, 1))
        var height = width * natural.height / natural.width
        if height > maxHeight {
            height = maxHeight
            width = max(natural.width * height / natural.height, 1)
        }
        return NSSize(width: width, height: height)
    }
}
