import AppKit
import Foundation
import Observation

/// One Markdown document being edited.
///
/// While editing, the source of truth is the attributed string in the text view;
/// Markdown only exists at the file boundary (parse on open, serialize on save).
@Observable
final class DocumentModel {
    /// Location on disk. `nil` means the document has never been saved.
    var fileURL: URL?

    /// True when the edited content differs from what's on disk.
    var isDirty = false

    /// Live word count for the status bar (updated by the editor on edits).
    var wordCount = 0

    /// Live character count for the status bar (updated by the editor on edits).
    var characterCount = 0

    /// Markdown waiting to be installed into the editor; the view consumes it
    /// (set by File open/new, cleared by the editor after loading).
    var pendingMarkdown: String?

    /// Live text storage, owned by the editor view (nil before first display).
    @ObservationIgnored weak var textStorage: NSTextStorage?

    var title: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Replaces the editor content with the given Markdown source.
    func loadMarkdown(_ markdown: String) {
        pendingMarkdown = markdown
    }

    /// The current content as Markdown (used on save).
    func serializedMarkdown() -> String? {
        if let textStorage {
            return MarkdownSerializer.serialize(textStorage)
        }
        return pendingMarkdown
    }
}
