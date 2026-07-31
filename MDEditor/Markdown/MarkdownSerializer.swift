import AppKit

/// Serializes the editor's attributed string back to canonical GitHub-Flavored
/// Markdown text.
///
/// Canonical style: ATX headings with one space, `-` bullets, sequential
/// ordered numbers, ``` code fences, `---` rules, pipe tables, blocks
/// separated by exactly one blank line, no trailing whitespace, file ending
/// in a single newline.
enum MarkdownSerializer {
    /// Converts an attributed string (as produced by `AttributedStringBuilder`)
    /// into canonical Markdown text.
    static func serialize(_ attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }
        let paragraphs = splitParagraphs(attributedString)
        let emitter = Emitter(attributedString: attributedString)
        let lines = emitter.emit(paragraphs[...], quoteDepth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits the string into paragraphs on `\n` only.
    ///
    /// `NSString.paragraphRange` is deliberately not used: it would also
    /// split on U+2028, which code and raw blocks use as an in-paragraph
    /// line separator.
    private static func splitParagraphs(_ attributedString: NSAttributedString) -> [MDParagraph] {
        let string = attributedString.string as NSString
        var paragraphs: [MDParagraph] = []
        var location = 0
        while location < string.length {
            var newline = location
            while newline < string.length && string.character(at: newline) != 0x0A {
                newline += 1
            }
            let contentRange = NSRange(location: location, length: newline - location)
            paragraphs.append(MDParagraph(
                text: string.substring(with: contentRange),
                contentRange: contentRange,
                attributes: attributedString.attributes(at: location, effectiveRange: nil)
            ))
            location = newline + 1
        }
        return paragraphs
    }
}

/// One `\n`-delimited paragraph with its paragraph-level attributes.
private struct MDParagraph {
    let text: String
    let contentRange: NSRange
    let attributes: [NSAttributedString.Key: Any]

    var quoteDepth: Int { attributes[MDAttr.blockQuoteDepth] as? Int ?? 0 }
    var rawBlock: String? { attributes[MDAttr.rawBlock] as? String }
    var isThematicBreak: Bool { attributes[MDAttr.thematicBreak] as? Bool ?? false }
    var codeBlockLanguage: String? { attributes[MDAttr.codeBlock] as? String }
    var headingLevel: Int? { attributes[MDAttr.headingLevel] as? Int }

    var paragraphStyle: NSParagraphStyle? { attributes[.paragraphStyle] as? NSParagraphStyle }
    var textLists: [NSTextList]? { paragraphStyle?.textLists }

    var tableBlock: NSTextTableBlock? {
        paragraphStyle?.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
    }
}

/// Line separator used inside paragraphs; emitted as a backslash hard break.
private let lineSeparator = "\u{2028}"

/// Emits Markdown lines for a sequence of paragraphs.
private struct Emitter {
    let attributedString: NSAttributedString

    /// One active list in the nesting stack, tracked by object identity.
    struct ListState {
        let id: ObjectIdentifier
        let ordered: Bool
        var counter: Int
        var lastMarker: String
    }

    /// Chunk identity for blank-line separation: consecutive items of the
    /// same outer list stay tight, everything else gets one blank line.
    enum ChunkTag {
        case list(ObjectIdentifier)
        case other
    }

    // MARK: - Block emission

    func emit(_ paragraphs: ArraySlice<MDParagraph>, quoteDepth: Int) -> [String] {
        var lines: [String] = []
        var listStack: [ListState] = []
        var previousTag: ChunkTag?

        func separator(before tag: ChunkTag, isContinuation: Bool) {
            guard let previousTag else { return }
            var tight = false
            if case .list(let previous) = previousTag, case .list(let current) = tag {
                tight = previous == current && !isContinuation
            }
            if !tight { lines.append("") }
        }

        var index = paragraphs.startIndex
        while index < paragraphs.endIndex {
            let paragraph = paragraphs[index]

            // Nested block-quote region: emit the run one level deeper and
            // prefix every line with "> ".
            if paragraph.quoteDepth > quoteDepth {
                var end = index
                while end < paragraphs.endIndex && paragraphs[end].quoteDepth > quoteDepth {
                    end += 1
                }
                let inner = emit(paragraphs[index..<end], quoteDepth: quoteDepth + 1)
                separator(before: .other, isContinuation: false)
                lines.append(contentsOf: inner.map { $0.isEmpty ? ">" : "> " + $0 })
                previousTag = .other
                index = end
                continue
            }

            if let raw = paragraph.rawBlock {
                separator(before: .other, isContinuation: false)
                lines.append(contentsOf: raw.components(separatedBy: "\n"))
                previousTag = .other
            } else if paragraph.isThematicBreak {
                separator(before: .other, isContinuation: false)
                lines.append("---")
                previousTag = .other
            } else if let language = paragraph.codeBlockLanguage {
                separator(before: .other, isContinuation: false)
                lines.append(contentsOf: codeBlockLines(language: language, content: paragraph.text))
                previousTag = .other
            } else if let table = paragraph.tableBlock?.table {
                var end = index + 1
                while end < paragraphs.endIndex, paragraphs[end].tableBlock?.table === table {
                    end += 1
                }
                separator(before: .other, isContinuation: false)
                lines.append(contentsOf: tableLines(Array(paragraphs[index..<end])))
                previousTag = .other
                index = end
                continue
            } else if let level = paragraph.headingLevel {
                separator(before: .other, isContinuation: false)
                let content = inline(paragraph)
                let prefix = String(repeating: "#", count: level) + (content.isEmpty ? "" : " ")
                lines.append(contentsOf: withPrefixOnFirstLine(prefix, content))
                previousTag = .other
            } else if let textLists = paragraph.textLists, !textLists.isEmpty {
                let isContinuation = !(paragraph.attributes[MDAttr.listItemStart] as? Bool ?? true)
                let tag = ChunkTag.list(ObjectIdentifier(textLists[0]))
                separator(before: tag, isContinuation: isContinuation)
                lines.append(contentsOf: listItemLines(
                    paragraph,
                    textLists: textLists,
                    isContinuation: isContinuation,
                    listStack: &listStack
                ))
                previousTag = tag
            } else {
                separator(before: .other, isContinuation: false)
                lines.append(contentsOf: withPrefixOnFirstLine("", inline(paragraph)))
                previousTag = .other
            }
            index += 1
        }
        return lines
    }

    /// Splits content into lines and puts the prefix on the first line only
    /// (hard-break continuation lines are lazy).
    private func withPrefixOnFirstLine(_ prefix: String, _ content: String) -> [String] {
        var contentLines = content.components(separatedBy: "\n")
        contentLines[0] = prefix + contentLines[0]
        return contentLines
    }

    // MARK: - Code blocks

    private func codeBlockLines(language: String, content: String) -> [String] {
        let text = content.replacingOccurrences(of: lineSeparator, with: "\n")
        let longestRun = longestRun(of: "`", in: text)
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        var lines = [fence + language]
        if !text.isEmpty {
            lines.append(contentsOf: text.components(separatedBy: "\n"))
        }
        lines.append(fence)
        return lines
    }

    // MARK: - Tables

    private func tableLines(_ cells: [MDParagraph]) -> [String] {
        var grid: [Int: [Int: String]] = [:]
        var headerRow = 0
        for cell in cells {
            guard let block = cell.tableBlock else { continue }
            grid[block.startingRow, default: [:]][block.startingColumn] = inline(cell, inTableCell: true)
            if cell.attributes[MDAttr.tableHeader] as? Bool == true {
                headerRow = block.startingRow
            }
        }
        let alignments = cells.first?.attributes[MDAttr.tableAlignments] as? [String] ?? []
        let rowCount = (grid.keys.max() ?? -1) + 1
        let columnCount = max(1, (grid.values.flatMap(\.keys).max() ?? -1) + 1)

        func rowLine(_ row: Int) -> String {
            let texts = (0..<columnCount).map { grid[row]?[$0] ?? "" }
            return "| " + texts.joined(separator: " | ") + " |"
        }

        var lines = [rowLine(headerRow)]
        lines.append("| " + (0..<columnCount).map { column in
            switch column < alignments.count ? alignments[column] : "" {
            case "left": return ":---"
            case "center": return ":---:"
            case "right": return "---:"
            default: return "---"
            }
        }.joined(separator: " | ") + " |")
        for row in 0..<rowCount where row != headerRow {
            lines.append(rowLine(row))
        }
        return lines
    }

    // MARK: - Lists

    private func listItemLines(
        _ paragraph: MDParagraph,
        textLists: [NSTextList],
        isContinuation: Bool,
        listStack: inout [ListState]
    ) -> [String] {
        // Reconcile the active stack with this paragraph's lists by identity.
        var depth = 0
        while depth < listStack.count && depth < textLists.count
                && listStack[depth].id == ObjectIdentifier(textLists[depth]) {
            depth += 1
        }
        listStack.removeLast(listStack.count - depth)
        while depth < textLists.count {
            let list = textLists[depth]
            let ordered = list.markerFormat == .decimal
            listStack.append(ListState(
                id: ObjectIdentifier(list),
                ordered: ordered,
                counter: list.startingItemNumber - 1,
                lastMarker: ordered ? "\(list.startingItemNumber)." : "-"
            ))
            depth += 1
        }

        let itemDepth = textLists.count - 1
        let content = inline(paragraph)
        let contentLines = content.components(separatedBy: "\n")

        if isContinuation {
            let indent = contentIndent(of: listStack, through: itemDepth)
            return [indent + contentLines[0]] + contentLines.dropFirst()
        }

        listStack[itemDepth].counter += 1
        let marker = listStack[itemDepth].ordered ? "\(listStack[itemDepth].counter)." : "-"
        listStack[itemDepth].lastMarker = marker

        var prefix = contentIndent(of: listStack, through: itemDepth - 1) + marker
        if let checked = paragraph.attributes[MDAttr.checkbox] as? Bool {
            prefix += " [\(checked ? "x" : " ")]"
        }
        if contentLines[0].isEmpty {
            return [prefix] + contentLines.dropFirst()
        }
        return [prefix + " " + contentLines[0]] + contentLines.dropFirst()
    }

    /// Total indentation of content at the given stack level, based on the
    /// actual marker widths ("- " is 2, "1. " is 3, "10. " is 4, ...).
    private func contentIndent(of stack: [ListState], through level: Int) -> String {
        guard level >= 0, !stack.isEmpty else { return "" }
        var width = 0
        for index in 0...Swift.min(level, stack.count - 1) {
            width += stack[index].lastMarker.count + 1
        }
        return String(repeating: " ", count: width)
    }

    // MARK: - Inline emission

    /// Active emphasis/link marker, emitted with a stack so that adjacent
    /// runs sharing markers keep them open (e.g. bold "a" + bold-italic "b"
    /// becomes `**a*b***`, never the misparsable `**a***b***`).
    private enum Marker: Equatable {
        case link(String, String?)
        case strike
        case strong
        case em

        var opener: String {
            switch self {
            case .link: return "["
            case .strike: return "~~"
            case .strong: return "**"
            case .em: return "*"
            }
        }

        var closer: String {
            switch self {
            case .link(let destination, let title):
                var closer = "](" + markdownLinkDestination(destination)
                if let title {
                    closer += " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                }
                return closer + ")"
            case .strike: return "~~"
            case .strong: return "**"
            case .em: return "*"
            }
        }
    }

    private struct Segment {
        var text: String
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link: String?
        var linkTitle: String?
        var image: MDImageAttachment?

        struct Signature: Equatable {
            var bold, italic, strike, code: Bool
            var link: String?
            var linkTitle: String?
            var imageID: ObjectIdentifier?
        }

        var signature: Signature {
            Signature(bold: bold, italic: italic, strike: strike, code: code,
                      link: link, linkTitle: linkTitle,
                      imageID: image.map { ObjectIdentifier($0) })
        }
    }

    private func inline(_ paragraph: MDParagraph, inTableCell: Bool = false) -> String {
        var segments: [Segment] = []
        attributedString.enumerateAttributes(in: paragraph.contentRange, options: []) { attributes, range, _ in
            segments.append(makeSegment(
                text: (attributedString.string as NSString).substring(with: range),
                attributes: attributes
            ))
        }
        let prepared = mergeAdjacent(segments.filter { !$0.text.isEmpty })
        return emitInline(prepared, inTableCell: inTableCell)
    }

    private func makeSegment(text: String, attributes: [NSAttributedString.Key: Any]) -> Segment {
        var segment = Segment(text: text)
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            segment.bold = traits.contains(.bold)
            segment.italic = traits.contains(.italic)
        }
        segment.strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        segment.code = attributes[MDAttr.inlineCode] as? Bool ?? false
        if let url = attributes[.link] as? URL {
            segment.link = url.absoluteString
        } else if let string = attributes[.link] as? String {
            segment.link = string
        }
        segment.linkTitle = attributes[MDAttr.linkTitle] as? String
        segment.image = attributes[.attachment] as? MDImageAttachment
        return segment
    }

    private func mergeAdjacent(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            if let last = merged.last, last.signature == segment.signature {
                merged[merged.count - 1].text += segment.text
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// One segment prepared for emission: its marker stack plus whitespace
    /// split off its edges. Markdown emphasis cannot start or end with
    /// whitespace, so edge whitespace is emitted at the transition point —
    /// inside markers that stay open, outside markers that open or close.
    private struct Prepared {
        let segment: Segment
        var desired: [Marker] = []
        var leading = ""
        var core = ""
        var trailing = ""
    }

    private func prepare(_ segment: Segment) -> Prepared {
        var prepared = Prepared(segment: segment)
        if let link = segment.link { prepared.desired.append(.link(link, segment.linkTitle)) }
        if segment.strike { prepared.desired.append(.strike) }
        if segment.bold { prepared.desired.append(.strong) }
        if segment.italic { prepared.desired.append(.em) }

        prepared.core = segment.text
        let hasFlankingMarkers = segment.bold || segment.italic || segment.strike
        guard hasFlankingMarkers, !segment.code, segment.image == nil else {
            return prepared
        }
        let isWhitespace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard !segment.text.allSatisfy(isWhitespace) else {
            // All-whitespace marked run: keep it inside a link if present
            // (legal), otherwise drop the unusable emphasis markers.
            prepared.desired = prepared.desired.filter {
                if case .link = $0 { return true }
                return false
            }
            return prepared
        }
        prepared.leading = String(segment.text.prefix(while: isWhitespace))
        let trailingCount = segment.text.reversed().prefix(while: isWhitespace).count
        prepared.trailing = String(segment.text.suffix(trailingCount))
        prepared.core = String(segment.text.dropFirst(prepared.leading.count).dropLast(trailingCount))
        return prepared
    }

    private func emitInline(_ segments: [Segment], inTableCell: Bool) -> String {
        let prepared = segments.map(prepare)
        var result = ""
        var stack: [Marker] = []
        var isAtParagraphStart = true
        var pendingWhitespace = ""

        for (index, item) in prepared.enumerated() {
            var common = 0
            while common < stack.count && common < item.desired.count && stack[common] == item.desired[common] {
                common += 1
            }
            for marker in stack[common...].reversed() { result += marker.closer }
            stack.removeLast(stack.count - common)
            result += pendingWhitespace + item.leading
            pendingWhitespace = ""
            for marker in item.desired[common...] {
                result += marker.opener
                stack.append(marker)
            }

            if let image = item.segment.image {
                result += imageMarkdown(image)
                isAtParagraphStart = false
            } else if item.segment.code {
                result += codeSpanMarkdown(item.segment.text)
                isAtParagraphStart = false
            } else if !item.core.isEmpty {
                var text = escapePlain(item.core, inTableCell: inTableCell, atLineStart: isAtParagraphStart)
                // A plain "!" immediately before a link turns it into an image.
                let nextIsLink = index + 1 < prepared.count && prepared[index + 1].desired.contains {
                    if case .link = $0 { return true }
                    return false
                }
                if nextIsLink && text.hasSuffix("!") {
                    text = String(text.dropLast()) + "\\!"
                }
                result += text
                isAtParagraphStart = false
            }
            pendingWhitespace = item.trailing
        }
        for marker in stack.reversed() { result += marker.closer }
        result += pendingWhitespace

        if result.contains(lineSeparator) {
            result = result.replacingOccurrences(of: lineSeparator, with: inTableCell ? " " : "\\\n")
        }
        return result
    }

    private func imageMarkdown(_ image: MDImageAttachment) -> String {
        var markdown = "![" + escapeAltText(image.altText) + "](" + markdownLinkDestination(image.source)
        if let title = image.title {
            markdown += " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return markdown + ")"
    }

    /// Inline code span: fence one longer than the longest backtick run in
    /// the content, padded with a space when the content touches the fence.
    private func codeSpanMarkdown(_ content: String) -> String {
        guard !content.isEmpty else { return "" }
        let fence = String(repeating: "`", count: longestRun(of: "`", in: content) + 1)
        let allSpaces = content.allSatisfy { $0 == " " }
        let touchesFence = content.hasPrefix("`") || content.hasSuffix("`")
            || content.hasPrefix(" ") || content.hasSuffix(" ")
        let pad = touchesFence && !allSpaces ? " " : ""
        return fence + pad + content + pad + fence
    }

    private func escapeAltText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - Plain-text escaping

    /// Escapes only what would otherwise be misparsed: `\` `` ` `` `*` `_`
    /// `[` `]`, `~~` runs, entity-looking `&…;`, tag/autolink-looking `<`,
    /// `|` inside table cells, and paragraph-leading `#`, `-`, `+`, `>`, `N.`.
    private func escapePlain(_ text: String, inTableCell: Bool, atLineStart: Bool) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        escaped = escapeTildeRuns(escaped)
        escaped = escapeEntities(escaped)
        escaped = escapeTagOpeners(escaped)
        if inTableCell {
            escaped = escaped.replacingOccurrences(of: "|", with: "\\|")
        }
        if atLineStart {
            escaped = escapeLineLeading(escaped)
        }
        return escaped
    }

    /// `~~` runs would reparse as strikethrough; escape every tilde in them.
    private func escapeTildeRuns(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "~" {
                var end = index
                while end < text.endIndex && text[end] == "~" {
                    end = text.index(after: end)
                }
                let count = text[index..<end].count
                result += count >= 2 ? String(repeating: "\\~", count: count) : "~"
                index = end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    /// `&` starting a valid-looking entity reference is emitted as `&amp;`.
    private func escapeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = "&(#\\d{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "&amp;$1;")
    }

    /// `<` that could open a tag or autolink is backslash-escaped.
    private func escapeTagOpeners(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let regex = try! NSRegularExpression(pattern: "<(?=[A-Za-z!?/])")
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\\\\<")
    }

    /// Escapes markers that would start a heading, list, quote, rule or
    /// ordered item at the beginning of a paragraph.
    private func escapeLineLeading(_ text: String) -> String {
        func matches(_ pattern: String) -> Bool {
            try! NSRegularExpression(pattern: pattern)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        // ATX heading, list marker, or a run of dashes (thematic break).
        if matches("^(#{1,6})(?=[ \\t]|$)") || matches("^[-+]+(?=[ \\t]|$)") {
            return "\\" + text
        }
        // Block quote marker.
        if text.first == ">" {
            return "\\" + text
        }
        // Ordered-list marker: `1. `, `12) `, ...
        let ordered = try! NSRegularExpression(pattern: "^(\\d{1,9})([.)])(?=[ \\t]|$)")
        if let match = ordered.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let delimiterRange = Range(match.range(at: 2), in: text) {
            var escaped = text
            escaped.insert("\\", at: delimiterRange.lowerBound)
            return escaped
        }
        return text
    }
}

/// Longest consecutive run of the given character in the string.
private func longestRun(of character: Character, in string: String) -> Int {
    var longest = 0
    var current = 0
    for element in string {
        if element == character {
            current += 1
            longest = max(longest, current)
        } else {
            current = 0
        }
    }
    return longest
}

/// Wraps a link/image destination in `<>` when it contains spaces or parens.
private func markdownLinkDestination(_ destination: String) -> String {
    if destination.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) {
        return "<" + destination + ">"
    }
    return destination
}
