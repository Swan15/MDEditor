import SwiftUI

/// Word and character counts for the status bar.
enum TextStatistics {
    /// Placeholder characters that are never user content: attachment objects
    /// (U+FFFC), the non-breaking space standing in for a rule (U+00A0) and
    /// in-paragraph line separators (U+2028).
    private static func isPlaceholder(_ character: Character) -> Bool {
        character == "\u{FFFC}" || character == "\u{00A0}" || character == "\u{2028}"
    }

    /// Grapheme count, excluding placeholders.
    static func characterCount(_ string: String) -> Int {
        string.filter { !isPlaceholder($0) }.count
    }

    /// Whitespace-delimited token count. Placeholders count as separators, so
    /// text either side of them is never glued into one "word".
    static func wordCount(_ string: String) -> Int {
        string.split(whereSeparator: { $0.isWhitespace || isPlaceholder($0) }).count
    }
}

/// Bottom editor bar: file name, modified indicator, live word/character counts.
struct StatusBarView: View {
    let document: DocumentModel

    var body: some View {
        HStack(spacing: 6) {
            Text(document.title)
            if document.isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.secondary)
                    .help("Unsaved changes")
                    .accessibilityLabel("Modified")
            }
            Spacer()
            Text("\(document.wordCount) words")
            Text("\(document.characterCount) characters")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
