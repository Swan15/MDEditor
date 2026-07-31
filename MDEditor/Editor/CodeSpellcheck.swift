import AppKit

/// Keeps the continuous spell checker's markings out of code.
///
/// The checker underlines "misspelled" identifiers in code blocks, raw
/// blocks and inline code — noise in a Markdown editor. It applies those
/// underlines as a TEMPORARY attribute (`.spellingState`, spelling and
/// grammar flags alike) through the layout manager, so the fix is to
/// strip that attribute from every range carrying code semantics. Prose
/// is never touched; checking stays enabled everywhere.
enum CodeSpellcheck {
    /// Removes spelling/grammar markings from all code ranges intersecting
    /// `range`. Idempotent, so it is safe to run after every edit and again
    /// once the checker's own (asynchronous) marking pass has settled.
    static func clearMarksInCode(storage: NSTextStorage, layoutManager: NSLayoutManager, range: NSRange? = nil) {
        guard storage.length > 0 else { return }
        let sweep = range ?? NSRange(location: 0, length: storage.length)
        storage.enumerateMDParagraphs(in: sweep) { paragraph in
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            if attributes[MDAttr.codeBlock] != nil || attributes[MDAttr.rawBlock] != nil {
                layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: paragraph)
                return
            }
            // Inline code runs inside otherwise ordinary paragraphs.
            storage.enumerateAttribute(MDAttr.inlineCode, in: paragraph) { value, run, _ in
                if value as? Bool == true {
                    layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: run)
                }
            }
        }
    }
}
