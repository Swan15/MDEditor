import AppKit

/// Loads, scales and edits Markdown image attachments.
///
/// Headless and view-free (like `TableController` / `FormatCommands`): every
/// function works on the text storage and plain values, so the whole feature
/// is testable without AppKit views. The editor coordinator supplies the UI
/// (panels, popovers) and calls in here.
///
/// Sources are resolved against the document's directory (relative paths) or
/// as absolute file paths. Remote URLs (`https://…`) are never fetched —
/// MDEditor is offline-first; remote loading is a future opt-in feature and
/// until then such images render as a labelled placeholder. Missing or
/// unreadable local files also render a placeholder; `source` is always left
/// untouched so saving never loses the reference.
enum ImageAttachmentController {
    /// Fallback height cap before the editor reports its real visible height.
    static let defaultMaxDisplayHeight: CGFloat = 640

    /// Fixed size of the generated placeholder image.
    static let placeholderSize = NSSize(width: 240, height: 64)

    // MARK: - Scaling

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

    /// Sets the height cap on every image attachment (window-resize hook).
    /// Returns true when any attachment changed, meaning layout is stale.
    @discardableResult
    static func setMaxDisplayHeight(_ height: CGFloat, in storage: NSTextStorage) -> Bool {
        var changed = false
        for (attachment, _) in imageAttachments(in: storage) where attachment.maxDisplayHeight != height {
            attachment.maxDisplayHeight = height
            changed = true
        }
        return changed
    }

    // MARK: - Enumeration and lookup

    /// Every image attachment in the storage with its character range.
    static func imageAttachments(in storage: NSTextStorage) -> [(attachment: MDImageAttachment, range: NSRange)] {
        var result: [(MDImageAttachment, NSRange)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? MDImageAttachment {
                result.append((attachment, range))
            }
        }
        return result
    }

    /// The image attachment at a character index, if any.
    static func imageAttachment(
        at charIndex: Int,
        in storage: NSTextStorage
    ) -> (attachment: MDImageAttachment, range: NSRange)? {
        guard charIndex >= 0, charIndex < storage.length else { return nil }
        var effectiveRange = NSRange()
        guard let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: &effectiveRange)
                as? MDImageAttachment else { return nil }
        return (attachment, effectiveRange)
    }

    // MARK: - Source resolution

    /// Where an image source points.
    enum ResolvedSource: Equatable {
        /// No source at all.
        case empty
        /// http/https or any other non-file scheme — never fetched.
        case remote
        /// A relative source but the document was never saved.
        case missingDocument
        /// A local file URL (relative resolved against the document).
        case localFile(URL)
    }

    /// Resolves a markdown image source to a loadable file URL or a reason
    /// it can't be loaded locally.
    static func resolve(source: String, documentURL: URL?) -> ResolvedSource {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        if let url = URL(string: trimmed), url.scheme != nil {
            return .remote
        }
        if trimmed.hasPrefix("/") {
            return .localFile(URL(fileURLWithPath: trimmed))
        }
        guard let documentURL else { return .missingDocument }
        return .localFile(documentURL.deletingLastPathComponent().appendingPathComponent(trimmed))
    }

    /// Alternate file URL for percent-encoded sources (`assets/my%20pic.png`
    /// meaning the file `assets/my pic.png`), or nil when not applicable.
    static func percentDecodedFileURL(source: String, documentURL: URL?) -> URL? {
        guard source.contains("%"), let decoded = source.removingPercentEncoding, decoded != source else { return nil }
        if case .localFile(let url) = resolve(source: decoded, documentURL: documentURL) {
            return url
        }
        return nil
    }

    // MARK: - Loading

    /// Outcome of a single file load.
    enum LoadOutcome: Equatable {
        case loaded
        case missing
        case permissionDenied
        case unreadable
    }

    /// A failed local load, kept so the editor can retry after a folder grant.
    struct ImageLoadFailure {
        let attachment: MDImageAttachment
        let url: URL
        let range: NSRange
        let isPermissionDenied: Bool
    }

    /// Result of `loadImages`.
    struct ImageLoadReport {
        var failures: [ImageLoadFailure] = []
        /// True when at least one attachment got real image data.
        var loadedAny = false
        /// True when any failure was a sandbox permission denial (the cue to
        /// offer the one-time folder-access prompt).
        var hasPermissionFailures: Bool { failures.contains(where: \.isPermissionDenied) }
    }

    /// Loads every not-yet-loaded image attachment in the storage.
    ///
    /// With `retryPlaceholders`, attachments currently showing a placeholder
    /// are re-resolved too (used after a save gives the document a location,
    /// or after a folder grant). Real loaded images are never touched.
    @discardableResult
    static func loadImages(
        in storage: NSTextStorage,
        documentURL: URL?,
        scope: SecurityScope?,
        retryPlaceholders: Bool = false
    ) -> ImageLoadReport {
        var report = ImageLoadReport()
        for (attachment, range) in imageAttachments(in: storage) {
            // Real loaded images are never touched; placeholders are only
            // re-resolved when asked (after a save or a folder grant).
            guard attachment.image == nil || (retryPlaceholders && attachment.isPlaceholder) else { continue }
            switch resolve(source: attachment.source, documentURL: documentURL) {
            case .empty:
                applyPlaceholder(attachment, reason: .unreadable)
            case .remote:
                applyPlaceholder(attachment, reason: .remote)
            case .missingDocument:
                applyPlaceholder(attachment, reason: .noDocument)
            case .localFile(let url):
                var outcome = load(attachment: attachment, fromFile: url, scope: scope)
                if outcome == .missing, let decoded = percentDecodedFileURL(source: attachment.source, documentURL: documentURL) {
                    outcome = load(attachment: attachment, fromFile: decoded, scope: scope)
                }
                switch outcome {
                case .loaded:
                    report.loadedAny = true
                case .missing, .permissionDenied, .unreadable:
                    applyPlaceholder(attachment, reason: outcome == .unreadable ? .unreadable : .missing)
                    report.failures.append(ImageLoadFailure(
                        attachment: attachment, url: url, range: range,
                        isPermissionDenied: outcome == .permissionDenied
                    ))
                }
            }
        }
        return report
    }

    /// Retries failed loads after a folder-access grant. Returns the number
    /// of attachments that recovered (layout must be invalidated then).
    @discardableResult
    static func retryLoads(_ failures: [ImageLoadFailure], scope: SecurityScope?) -> Int {
        var recovered = 0
        for failure in failures where load(attachment: failure.attachment, fromFile: failure.url, scope: scope) == .loaded {
            recovered += 1
        }
        return recovered
    }

    /// Loads one attachment from a local file URL, setting `image` and
    /// `naturalSize` on success. Never throws; failures are categorical.
    @discardableResult
    static func load(attachment: MDImageAttachment, fromFile url: URL, scope: SecurityScope?) -> LoadOutcome {
        // Best effort: false only means "no scope needed or none available";
        // the read below is the real verdict.
        _ = scope?.ensureAccess(to: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
                return .permissionDenied
            }
            return .missing
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return .unreadable
        }
        attachment.image = image
        attachment.naturalSize = image.size
        attachment.isPlaceholder = false
        return .loaded
    }

    // MARK: - Placeholders

    /// Why a placeholder is shown instead of the image.
    enum PlaceholderReason {
        /// File not found (or not readable due to permissions).
        case missing
        /// File exists but can't be decoded as an image.
        case unreadable
        /// Remote URL — deliberately not fetched (offline-first).
        case remote
        /// Relative source in a never-saved document.
        case noDocument

        var label: String {
            switch self {
            case .missing: return "Missing image"
            case .unreadable: return "Image not readable"
            case .remote: return "Remote image (not loaded)"
            case .noDocument: return "Save the document to load this image"
            }
        }
    }

    /// Installs a generated placeholder so a broken reference is never blank.
    /// `source` stays untouched — the markdown reference survives the save.
    static func applyPlaceholder(_ attachment: MDImageAttachment, reason: PlaceholderReason) {
        let image = placeholderImage(source: attachment.source, reason: reason)
        attachment.image = image
        attachment.naturalSize = image.size
        attachment.isPlaceholder = true
    }

    /// Dashed-box placeholder naming the reason and the source. Drawn with a
    /// drawing handler so semantic colors (label/secondaryLabel) re-resolve
    /// on appearance changes — dark mode needs no rebuild.
    static func placeholderImage(source: String, reason: PlaceholderReason) -> NSImage {
        let size = placeholderSize
        return NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            box.fill()
            NSColor.secondaryLabelColor.setStroke()
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            box.stroke()

            let title = NSAttributedString(string: reason.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            title.draw(at: NSPoint(x: 10, y: size.height - 26))
            let detail = NSAttributedString(string: truncated(source, to: 38), attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            detail.draw(at: NSPoint(x: 10, y: 12))
            return true
        }
    }

    /// Middle-truncates long sources so the placeholder stays readable.
    private static func truncated(_ source: String, to limit: Int) -> String {
        guard source.count > limit else { return source }
        let head = source.prefix(limit * 2 / 3)
        let tail = source.suffix(limit / 3)
        return "\(head)…\(tail)"
    }

    // MARK: - Editing

    /// Inserts an image attachment at the selection (replacing any selected
    /// text). Returns the cursor position after the attachment.
    @discardableResult
    static func insert(attachment: MDImageAttachment, storage: NSTextStorage, selection: NSRange) -> Int {
        let location = min(max(selection.location, 0), storage.length)
        let range = NSRange(location: location, length: min(selection.length, storage.length - location))
        // Clean run attributes: inheriting the cursor's font/link would make
        // the serializer wrap the image in emphasis or a link.
        let attributed = NSAttributedString(string: "\u{FFFC}", attributes: [
            .attachment: attachment,
            .font: StyleEngine.bodyFont
        ])
        storage.replaceCharacters(in: range, with: attributed)
        return location + 1
    }

    /// Applies alt-text/title edits to an attachment (empty title clears it).
    /// The serializer picks the values up on the next save.
    static func applyAltEdit(altText: String, title: String?, to attachment: MDImageAttachment) {
        attachment.altText = altText
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespaces)
        attachment.title = trimmed.isEmpty ? nil : trimmed
    }
}
