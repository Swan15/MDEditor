import Foundation
import Markdown

/// A parsed Markdown document plus the source it was parsed from.
///
/// The source is kept so that node `range`s (1-based line, 1-based UTF-8
/// byte column) can be sliced back out of the original text — used to
/// preserve unsupported constructs verbatim.
struct ParsedDocument {
    /// The swift-markdown AST.
    let document: Document

    /// The exact string the document was parsed from.
    let source: String

    /// UTF-8 byte offset of the start of each line (line 1 = index 0).
    private let lineStartByteOffsets: [Int]

    init(parsing source: String) {
        // `.disableSmartOpts`: smart punctuation would silently rewrite the
        // user's text (`--` → `–`, `...` → `…`, straight → curly quotes),
        // which is unacceptable for an editor whose save path is Markdown.
        self.document = Document(parsing: source, options: [.disableSmartOpts])
        self.source = source
        var offsets = [0]
        for (index, byte) in source.utf8.enumerated() where byte == UInt8(ascii: "\n") {
            offsets.append(index + 1)
        }
        self.lineStartByteOffsets = offsets
    }

    /// The original source text covered by the given markup range, if valid.
    func sourceSlice(_ range: SourceRange?) -> String? {
        guard let range,
              let lower = byteOffset(of: range.lowerBound),
              let upper = byteOffset(of: range.upperBound),
              lower <= upper, upper <= source.utf8.count else {
            return nil
        }
        let utf8 = source.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: lower)
        let end = utf8.index(utf8.startIndex, offsetBy: upper)
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    private func byteOffset(of location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStartByteOffsets.count else {
            return nil
        }
        return lineStartByteOffsets[location.line - 1] + (location.column - 1)
    }
}

/// Entry point for turning Markdown text into a parsed AST.
enum MarkdownParser {
    /// Parses `source` with swift-markdown (GFM extensions on by default).
    static func parse(_ source: String) -> ParsedDocument {
        ParsedDocument(parsing: source)
    }
}
