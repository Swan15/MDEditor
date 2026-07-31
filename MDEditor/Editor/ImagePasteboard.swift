import AppKit
import UniformTypeIdentifiers

/// Image content on pasteboards (paste and drag alike).
///
/// Precedence: image flavors beat EVERYTHING else on the pasteboard — the
/// Markdown text conversion and the default rich paste both defer — so a
/// copied image always becomes a real document image (an `MDImageAttachment`
/// backed by an on-disk asset) instead of a rich-text-only attachment the
/// serializer couldn't express.
enum ImagePasteboard {
    /// Image content found on a pasteboard.
    enum Content {
        /// An image file (Finder drag/copy, Insert → Image…).
        case file(URL)
        /// Raw image data (screenshots, copies from image apps).
        case data(Data, suggestedName: String)
    }

    /// Raw-data flavors we consume, in precedence order (PNG first: that is
    /// what screenshots and most apps provide; TIFF covers the rest).
    static let imageDataTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// First raw-image flavor present in `availableTypes`, or nil.
    /// Logic-level seam: the paste/drop paths feed it the live type list.
    static func preferredImageDataType(from availableTypes: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imageDataTypes.first { availableTypes.contains($0) }
    }

    /// True when the file URL points at an image (UTI conformance).
    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Image content on the pasteboard, or nil: image file URLs first (keeps
    /// the original file and format), then raw image data.
    static func imageContent(from pasteboard: NSPasteboard) -> Content? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let imageURL = urls.first(where: isImageFile) {
            return .file(imageURL)
        }
        if let type = preferredImageDataType(from: pasteboard.types ?? []),
           let data = pasteboard.data(forType: type) {
            return .data(data, suggestedName: "pasted-image")
        }
        return nil
    }
}
