import AppKit

/// Table structure operations on the live text storage.
///
/// Every operation takes an `NSTextStorage` plus a selection, so it runs
/// headless in tests as well as against the editor's text view (the same
/// contract as `FormatCommands`). Operations only change *semantic* state —
/// cell paragraphs, their `NSTextTableBlock` row/column indices and the
/// `mdTableHeader`/`mdTableAlignments` attributes — and finish by re-styling
/// the table, which re-applies the visual chrome (borders, padding, header
/// shading) to any freshly created blocks.
///
/// The table model in the text: one paragraph per cell, row-major, each
/// carrying an `NSTextTableBlock` (0-based row/column) in
/// `paragraphStyle.textBlocks`; header-row paragraphs carry `mdTableHeader`;
/// every cell paragraph carries the table's `mdTableAlignments` array.
/// Invariants maintained by every operation: every row has the same column
/// count, row/column indices are dense from 0, exactly one header row, and
/// the serializer's output stays valid GFM (verified by round-trip tests).
enum TableController {
    // MARK: - Model

    /// One cell paragraph of a table.
    struct Cell {
        /// 0-based row (block index).
        let row: Int
        /// 0-based column (block index).
        let column: Int
        /// Paragraph range including the terminating newline.
        let range: NSRange
        /// Paragraph range without the terminating newline (may be empty).
        let contentRange: NSRange
        /// The paragraph's table block.
        let block: NSTextTableBlock
        /// True when the paragraph carries `mdTableHeader`.
        let isHeader: Bool
        /// The paragraph's `mdTableAlignments`, if present.
        let alignments: [String]?
    }

    /// A table's cells in document (row-major) order plus its dimensions.
    struct Model {
        let table: NSTextTable
        let cells: [Cell]
        /// Number of rows (highest block row index + 1).
        let rowCount: Int
        /// Number of columns (max of the table's and the blocks' counts).
        let columnCount: Int
        /// Per-column alignments ("left"/"center"/"right"/"").
        let alignments: [String]

        func cell(row: Int, column: Int) -> Cell? {
            cells.first { $0.row == row && $0.column == column }
        }

        func cellsInRow(_ row: Int) -> [Cell] {
            cells.filter { $0.row == row }.sorted { $0.column < $1.column }
        }

        func cellsInColumn(_ column: Int) -> [Cell] {
            cells.filter { $0.column == column }.sorted { $0.row < $1.row }
        }

        /// Character range covering the table's paragraphs.
        var range: NSRange {
            guard let first = cells.first, let last = cells.last else {
                return NSRange(location: 0, length: 0)
            }
            return NSRange(location: first.range.location,
                           length: NSMaxRange(last.range) - first.range.location)
        }
    }

    /// All tables in the storage, in document order.
    static func models(in storage: NSTextStorage) -> [Model] {
        guard storage.length > 0 else { return [] }
        let string = storage.string as NSString
        var order: [ObjectIdentifier] = []
        var buckets: [ObjectIdentifier: (table: NSTextTable, cells: [Cell])] = [:]
        storage.enumerateMDParagraphs(in: NSRange(location: 0, length: storage.length)) { paragraph in
            guard paragraph.length > 0, paragraph.location < storage.length else { return }
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            guard let style = attributes[.paragraphStyle] as? NSParagraphStyle,
                  let block = style.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
            else { return }
            var content = paragraph
            if string.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let cell = Cell(
                row: block.startingRow,
                column: block.startingColumn,
                range: paragraph,
                contentRange: content,
                block: block,
                isHeader: attributes[MDAttr.tableHeader] as? Bool == true,
                alignments: attributes[MDAttr.tableAlignments] as? [String]
            )
            let id = ObjectIdentifier(block.table)
            if buckets[id] == nil {
                order.append(id)
                buckets[id] = (block.table, [])
            }
            buckets[id]?.cells.append(cell)
        }
        return order.compactMap { id in
            guard let bucket = buckets[id], !bucket.cells.isEmpty else { return nil }
            let rowCount = (bucket.cells.map(\.row).max() ?? -1) + 1
            let columnCount = max(bucket.table.numberOfColumns, (bucket.cells.map(\.column).max() ?? -1) + 1)
            let alignments = bucket.cells.first(where: { $0.alignments != nil })?.alignments
                ?? Array(repeating: "", count: columnCount)
            return Model(table: bucket.table, cells: bucket.cells,
                         rowCount: rowCount, columnCount: columnCount, alignments: alignments)
        }
    }

    /// The table containing the paragraph at `location`, if any.
    static func model(at location: Int, in storage: NSTextStorage) -> Model? {
        guard storage.length > 0, location != NSNotFound else { return nil }
        let anchor = min(max(location, 0), storage.length - 1)
        let paragraph = storage.mdParagraphRange(for: NSRange(location: anchor, length: 0))
        guard paragraph.location < storage.length, let block = tableBlock(at: paragraph.location, in: storage) else {
            return nil
        }
        return models(in: storage).first { $0.table === block.table }
    }

    /// The cell whose content contains the caret position.
    static func cell(at cursor: Int, in model: Model) -> Cell? {
        model.cells.first { cursor >= $0.range.location && cursor <= NSMaxRange($0.contentRange) }
    }

    /// The table block of the paragraph starting at `location`, if any.
    private static func tableBlock(at location: Int, in storage: NSTextStorage) -> NSTextTableBlock? {
        guard location >= 0, location < storage.length else { return nil }
        let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
    }

    // MARK: - Insert table

    /// Inserts a 3-column × 2-row table (header + one body row, all columns
    /// left-aligned) after the paragraph containing the selection — or after
    /// the whole current table when the selection is inside one. Cells are
    /// empty paragraphs (serialized as `|  |`). Returns the caret position
    /// (start of the first header cell).
    @discardableResult
    static func insertTable(storage: NSTextStorage, selection: NSRange) -> Int {
        let table = NSTextTable()
        table.numberOfColumns = 3
        let alignments = ["left", "left", "left"]
        let text = NSMutableAttributedString()
        for row in 0..<2 {
            for column in 0..<3 {
                text.append(cellParagraph(table: table, row: row, column: column,
                                          isHeader: row == 0, alignments: alignments, terminated: true))
            }
        }
        var insertionPoint = 0
        if storage.length > 0 {
            let anchor = min(max(selection.location, 0), storage.length - 1)
            var end = NSMaxRange(storage.mdParagraphRange(for: NSRange(location: anchor, length: 0)))
            if let current = model(at: anchor, in: storage) {
                end = NSMaxRange(current.range)
            }
            // An unterminated anchor paragraph (end of document) needs its
            // separator before the table's first paragraph.
            let string = storage.string as NSString
            if end == storage.length, end > 0, string.character(at: end - 1) != 0x0A {
                let attributes = storage.attributes(at: end - 1, effectiveRange: nil)
                storage.insert(NSAttributedString(string: "\n", attributes: attributes), at: end)
                end += 1
            }
            insertionPoint = end
        }
        storage.insert(text, at: insertionPoint)
        restyle(table, in: storage)
        return insertionPoint
    }

    // MARK: - Tab navigation

    /// Tab (forward) / Shift-Tab (backward) inside a table cell: move the
    /// caret row-major through the cells. Tab in the last cell appends a
    /// body row and moves into its first cell (Word behavior); Shift-Tab in
    /// the first cell is swallowed. Returns nil when the caret is not in a
    /// table, letting the caller fall through to generic Tab handling.
    static func moveSelection(forward: Bool, in context: EditingBehavior.Context) -> EditingBehavior.Result? {
        let storage = context.storage
        guard storage.length > 0 else { return nil }
        let cursor = min(context.selection.location, storage.length)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return nil }
        let lastColumn = model.columnCount - 1
        if forward {
            if current.column < lastColumn {
                return navigate(to: current.row, current.column + 1, in: model, storage: storage)
            } else if current.row < model.rowCount - 1 {
                return navigate(to: current.row + 1, 0, in: model, storage: storage)
            } else {
                EditorUndo.registerUndo(
                    storage: storage, selection: context.selection,
                    undoManager: context.undoManager, actionName: "Insert Row",
                    restoreSelection: context.restoreSelection
                )
                guard let caret = insertRow(at: model.rowCount, model: model, storage: storage) else { return nil }
                return EditingBehavior.Result(
                    selection: NSRange(location: caret, length: 0),
                    typingAttributes: typingAttributes(at: caret, in: storage),
                    mutated: true
                )
            }
        } else {
            if current.column > 0 {
                return navigate(to: current.row, current.column - 1, in: model, storage: storage)
            } else if current.row > 0 {
                return navigate(to: current.row - 1, lastColumn, in: model, storage: storage)
            } else {
                return EditingBehavior.Result(selection: context.selection, typingAttributes: nil, mutated: false)
            }
        }
    }

    /// Caret to the end of the destination cell's content, with typing
    /// attributes mirroring the destination (header vs. body cell).
    private static func navigate(
        to row: Int, _ column: Int, in model: Model, storage: NSTextStorage
    ) -> EditingBehavior.Result? {
        guard let cell = model.cell(row: row, column: column) else { return nil }
        let caret = NSMaxRange(cell.contentRange)
        return EditingBehavior.Result(
            selection: NSRange(location: caret, length: 0),
            typingAttributes: typingAttributes(at: caret, in: storage),
            mutated: false
        )
    }

    /// Typing attributes for a cell position (attachments/links stripped).
    private static func typingAttributes(at location: Int, in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        var attributes = EditingBehavior.attributesForInsertion(at: location, in: storage)
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: MDAttr.linkTitle)
        return attributes
    }

    // MARK: - Row operations

    /// Inserts an empty body row above or below the row containing the
    /// selection. Returns the caret position (first cell of the new row).
    @discardableResult
    static func insertRow(above: Bool, storage: NSTextStorage, selection: NSRange) -> Int? {
        guard storage.length > 0 else { return nil }
        let cursor = min(max(selection.location, 0), storage.length - 1)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return nil }
        return insertRow(at: above ? current.row : current.row + 1, model: model, storage: storage)
    }

    /// Inserts an empty body row so it lands at `rowIndex` (0...rowCount),
    /// shifting the block row indices of the rows below down by one.
    private static func insertRow(at rowIndex: Int, model: Model, storage: NSTextStorage) -> Int? {
        guard rowIndex >= 0, rowIndex <= model.rowCount else { return nil }
        storage.beginEditing()
        for cell in model.cells where cell.row >= rowIndex {
            rewriteBlock(cell, row: cell.row + 1, column: cell.column, in: storage)
        }
        storage.endEditing()

        var insertionPoint: Int
        let text = NSMutableAttributedString()
        if let firstOfRow = model.cell(row: rowIndex, column: 0) {
            insertionPoint = firstOfRow.range.location
            for column in 0..<model.columnCount {
                text.append(cellParagraph(table: model.table, row: rowIndex, column: column,
                                          isHeader: false, alignments: model.alignments, terminated: true))
            }
        } else {
            // Appending after the last row: anchor on the row-major last cell.
            guard let anchor = model.cell(row: model.rowCount - 1, column: model.columnCount - 1) else { return nil }
            insertionPoint = NSMaxRange(anchor.range)
            if anchor.range.length == anchor.contentRange.length {
                // Document-final table: the anchor cell has no separator, so
                // add one before the new row's first paragraph.
                let attributes = storage.attributes(at: anchor.range.location, effectiveRange: nil)
                storage.insert(NSAttributedString(string: "\n", attributes: attributes), at: insertionPoint)
                insertionPoint += 1
            }
            for column in 0..<model.columnCount {
                text.append(cellParagraph(table: model.table, row: rowIndex, column: column,
                                          isHeader: false, alignments: model.alignments, terminated: true))
            }
            storage.insert(text, at: insertionPoint)
            restyle(model.table, in: storage)
            return insertionPoint
        }
        storage.insert(text, at: insertionPoint)
        restyle(model.table, in: storage)
        return insertionPoint
    }

    /// Deletes the row containing the selection, shifting the block row
    /// indices of the rows below up by one. The header row cannot be deleted
    /// (returns nil); deleting the last body row is allowed (a header-only
    /// table reparses as a table). Returns the caret position.
    @discardableResult
    static func deleteRow(storage: NSTextStorage, selection: NSRange) -> Int? {
        guard storage.length > 0 else { return nil }
        let cursor = min(max(selection.location, 0), storage.length - 1)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return nil }
        guard !current.isHeader else { return nil }
        let row = current.row
        let rowCells = model.cellsInRow(row)
        guard let first = rowCells.first, let last = rowCells.last else { return nil }
        var deletion = NSRange(location: first.range.location,
                               length: NSMaxRange(last.range) - first.range.location)
        if last.range.length == last.contentRange.length, deletion.location > 0 {
            // Document-final row has no trailing separator: take the
            // preceding one along instead.
            deletion = NSRange(location: deletion.location - 1, length: deletion.length + 1)
        }
        // Shift the rows below up first (attribute-only, so the character
        // ranges stay valid), then delete the row's paragraphs.
        storage.beginEditing()
        for cell in model.cells where cell.row > row {
            rewriteBlock(cell, row: cell.row - 1, column: cell.column, in: storage)
        }
        storage.endEditing()
        storage.deleteCharacters(in: deletion)
        restyle(model.table, in: storage)
        guard let updated = models(in: storage).first(where: { $0.table === model.table }) else {
            return min(deletion.location, storage.length)
        }
        let target = updated.cell(row: min(row, updated.rowCount - 1), column: 0)
            ?? updated.cell(row: updated.rowCount - 1, column: 0)
        return target.map { NSMaxRange($0.contentRange) } ?? min(deletion.location, storage.length)
    }

    // MARK: - Column operations

    /// Inserts an empty column left or right of the column containing the
    /// selection, shifting block column indices and inserting a "" entry in
    /// every cell paragraph's `mdTableAlignments`. Returns the caret
    /// position (the new cell in the current row).
    @discardableResult
    static func insertColumn(left: Bool, storage: NSTextStorage, selection: NSRange) -> Int? {
        guard storage.length > 0 else { return nil }
        let cursor = min(max(selection.location, 0), storage.length - 1)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return nil }
        let newIndex = left ? current.column : current.column + 1
        storage.beginEditing()
        for cell in model.cells where cell.column >= newIndex {
            rewriteBlock(cell, row: cell.row, column: cell.column + 1, in: storage)
        }
        storage.endEditing()
        model.table.numberOfColumns = model.columnCount + 1

        // One new cell paragraph per row, bottom-up so earlier (upper)
        // insertion points stay valid. Header-row cells stay header cells.
        var caret: Int?
        for row in (0..<model.rowCount).reversed() {
            guard let anchor = model.cell(row: row, column: current.column) else { continue }
            let terminated = anchor.range.length > anchor.contentRange.length
            if left {
                let paragraph = cellParagraph(table: model.table, row: row, column: newIndex,
                                              isHeader: anchor.isHeader, alignments: model.alignments, terminated: true)
                storage.insert(paragraph, at: anchor.range.location)
                if row == current.row { caret = anchor.range.location }
            } else {
                var point = NSMaxRange(anchor.range)
                if !terminated {
                    // Document-final table: the anchor cell has no
                    // separator, so add one before the new cell's paragraph.
                    let attributes = storage.attributes(at: anchor.range.location, effectiveRange: nil)
                    storage.insert(NSAttributedString(string: "\n", attributes: attributes), at: point)
                    point += 1
                }
                let paragraph = cellParagraph(table: model.table, row: row, column: newIndex,
                                              isHeader: anchor.isHeader, alignments: model.alignments, terminated: true)
                storage.insert(paragraph, at: point)
                if row == current.row { caret = point }
            }
        }
        var alignments = paddedAlignments(model)
        alignments.insert("", at: min(newIndex, alignments.count))
        if let updated = models(in: storage).first(where: { $0.table === model.table }) {
            setAlignments(alignments, on: updated, in: storage)
        }
        restyle(model.table, in: storage)
        return caret
    }

    /// Deletes the column containing the selection, shifting block column
    /// indices and removing the column's entry in `mdTableAlignments`. The
    /// last remaining column cannot be deleted (returns nil). Returns the
    /// caret position.
    @discardableResult
    static func deleteColumn(storage: NSTextStorage, selection: NSRange) -> Int? {
        guard storage.length > 0 else { return nil }
        let cursor = min(max(selection.location, 0), storage.length - 1)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return nil }
        guard model.columnCount > 1 else { return nil }
        let deleted = current.column
        // Shift columns right of the deleted one first (attribute-only, so
        // the character ranges stay valid), then delete the column's cell
        // paragraphs bottom-up; a document-final unterminated cell takes
        // the preceding separator along.
        storage.beginEditing()
        for cell in model.cells where cell.column > deleted {
            rewriteBlock(cell, row: cell.row, column: cell.column - 1, in: storage)
        }
        storage.endEditing()
        for cell in model.cellsInColumn(deleted).reversed() {
            var range = cell.range
            if range.length == cell.contentRange.length, range.location > 0 {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            storage.deleteCharacters(in: range)
        }
        model.table.numberOfColumns = model.columnCount - 1
        var alignments = paddedAlignments(model)
        if deleted < alignments.count { alignments.remove(at: deleted) }
        guard let updated = models(in: storage).first(where: { $0.table === model.table }) else {
            return min(cursor, storage.length)
        }
        setAlignments(alignments, on: updated, in: storage)
        restyle(model.table, in: storage)
        let target = updated.cell(row: current.row, column: min(deleted, updated.columnCount - 1))
        return target.map { NSMaxRange($0.contentRange) } ?? min(cursor, storage.length)
    }

    // MARK: - Alignment

    /// Cycles the alignment of the column containing the selection:
    /// "" → left → center → right → left.
    @discardableResult
    static func cycleAlignment(storage: NSTextStorage, selection: NSRange) -> Bool {
        guard storage.length > 0 else { return false }
        let cursor = min(max(selection.location, 0), storage.length - 1)
        guard let model = model(at: cursor, in: storage),
              let current = cell(at: cursor, in: model) else { return false }
        var alignments = paddedAlignments(model)
        let next: String
        switch alignments[current.column] {
        case "": next = "left"
        case "left": next = "center"
        case "center": next = "right"
        default: next = "left"
        }
        alignments[current.column] = next
        setAlignments(alignments, on: model, in: storage)
        restyle(model.table, in: storage)
        return true
    }

    // MARK: - Defensive cleanup

    /// Repairs tables intersecting `range` after arbitrary edits (e.g. a
    /// selection deletion that removed the header row or single cells):
    /// renumbers block row/column indices densely from 0, promotes a new
    /// header row when none remains, and syncs `numberOfColumns`. Keeps the
    /// serializer's output valid GFM. Attribute-only; safe to call from
    /// `textStorage(_:didProcessEditing:)`.
    static func sanitize(storage: NSTextStorage, around range: NSRange) {
        guard storage.length > 0, range.location != NSNotFound else { return }
        let union = storage.mdParagraphRange(for: range)
        guard union.location < storage.length else { return }
        var tableIDs = Set<ObjectIdentifier>()
        storage.enumerateMDParagraphs(in: union) { paragraph in
            guard paragraph.location < storage.length else { return }
            if let block = tableBlock(at: paragraph.location, in: storage) {
                tableIDs.insert(ObjectIdentifier(block.table))
            }
        }
        guard !tableIDs.isEmpty else { return }
        for model in models(in: storage) where tableIDs.contains(ObjectIdentifier(model.table)) {
            densify(model, in: storage)
        }
    }

    /// Renumbers a table's block indices densely and ensures a header row.
    private static func densify(_ model: Model, in storage: NSTextStorage) {
        let rows = Array(Set(model.cells.map(\.row))).sorted()
        let columns = Array(Set(model.cells.map(\.column))).sorted()
        let rowMap = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element, $0.offset) })
        let columnMap = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, $0.offset) })
        let needsShift = rows != Array(0..<rows.count) || columns != Array(0..<columns.count)
        let hasHeader = model.cells.contains(where: \.isHeader)
        guard needsShift || !hasHeader || model.table.numberOfColumns != columns.count else { return }
        storage.beginEditing()
        if needsShift {
            for cell in model.cells {
                rewriteBlock(cell, row: rowMap[cell.row]!, column: columnMap[cell.column]!, in: storage)
            }
        }
        if !hasHeader {
            // The header row was removed by a raw edit: promote row 0 so the
            // first row keeps its header styling (and the serializer its
            // delimiter row placement).
            for cell in model.cells where rowMap[cell.row] == 0 {
                storage.addAttribute(MDAttr.tableHeader, value: true, range: cell.range)
            }
        }
        model.table.numberOfColumns = max(columns.count, 1)
        storage.endEditing()
    }

    // MARK: - Helpers

    /// An empty cell paragraph (just its separator when terminated).
    private static func cellParagraph(
        table: NSTextTable, row: Int, column: Int,
        isHeader: Bool, alignments: [String], terminated: Bool
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)]
        var attributes: [NSAttributedString.Key: Any] = [
            .font: StyleEngine.bodyFont,
            .paragraphStyle: style,
            MDAttr.tableAlignments: alignments
        ]
        if isHeader {
            attributes[MDAttr.tableHeader] = true
        }
        return NSAttributedString(string: terminated ? "\n" : "", attributes: attributes)
    }

    /// Replaces a cell paragraph's block with one at a new row/column (block
    /// indices are read-only; the fresh block gets its chrome on restyle).
    private static func rewriteBlock(_ cell: Cell, row: Int, column: Int, in storage: NSTextStorage) {
        guard cell.range.location < storage.length,
              let style = (storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle else { return }
        style.textBlocks = [NSTextTableBlock(table: cell.block.table, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)]
        storage.addAttribute(.paragraphStyle, value: style, range: cell.range)
    }

    /// Sets the same alignments array on every cell paragraph of the table.
    private static func setAlignments(_ alignments: [String], on model: Model, in storage: NSTextStorage) {
        storage.beginEditing()
        for cell in model.cells {
            storage.addAttribute(MDAttr.tableAlignments, value: alignments, range: cell.range)
        }
        storage.endEditing()
    }

    /// The table's alignments padded to its column count with "".
    private static func paddedAlignments(_ model: Model) -> [String] {
        var alignments = model.alignments
        while alignments.count < model.columnCount { alignments.append("") }
        return alignments
    }

    /// Re-applies visual styling to the table's current extent.
    private static func restyle(_ table: NSTextTable, in storage: NSTextStorage) {
        guard let model = models(in: storage).first(where: { $0.table === table }) else { return }
        StyleEngine.style(storage, range: model.range)
    }
}
