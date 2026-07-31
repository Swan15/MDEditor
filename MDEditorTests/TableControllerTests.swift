import XCTest
import Markdown
@testable import MDEditor

/// Table structure operations driven headless against a text storage built
/// via parse → build, verified through block indices, semantic attributes
/// and the serializer (structure must round-trip after every operation).
final class TableControllerTests: XCTestCase {
    /// parse → build → storage (unstyled; operations style as they go).
    private func makeStorage(_ markdown: String = "") -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        MarkdownSerializer.serialize(storage)
    }

    private func roundTrip(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    private func context(
        _ storage: NSTextStorage, at location: Int,
        undoManager: UndoManager? = nil
    ) -> EditingBehavior.Context {
        EditingBehavior.Context(
            storage: storage,
            selection: NSRange(location: location, length: 0),
            undoManager: undoManager
        )
    }

    private func model(_ storage: NSTextStorage) -> TableController.Model {
        let models = TableController.models(in: storage)
        XCTAssertEqual(models.count, 1, "Expected exactly one table")
        return models[0]
    }

    /// 3×2 table (header + one body row). Storage text: "H1\nH2\nH3\na\nb\nc".
    private let table = """
    | H1 | H2 | H3 |
    | --- | --- | --- |
    | a | b | c |
    """

    /// 3×3 table (header + two body rows).
    private let table3 = """
    | H1 | H2 | H3 |
    | --- | --- | --- |
    | a | b | c |
    | d | e | f |
    """

    // MARK: - Insert table

    func testInsertTableIntoEmptyDocument() {
        let storage = makeStorage()
        let caret = TableController.insertTable(storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(caret, 0)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.columnCount, 3)
        XCTAssertEqual(model.cells.count, 6)
        XCTAssertEqual(model.table.numberOfColumns, 3)
        XCTAssertEqual(model.alignments, ["left", "left", "left"])
        for cell in model.cells {
            XCTAssertEqual(cell.isHeader, cell.row == 0)
            XCTAssertEqual(cell.row, cell.block.startingRow)
            XCTAssertEqual(cell.column, cell.block.startingColumn)
        }
        let expected = """
        |  |  |  |
        | :--- | :--- | :--- |
        |  |  |  |

        """
        XCTAssertEqual(serialize(storage), expected)
        XCTAssertEqual(roundTrip(expected), expected, "Inserted table must be a serialization fixpoint")
    }

    func testInsertTableAfterParagraph() {
        // Storage text: "Hello".
        let storage = makeStorage("Hello")
        let caret = TableController.insertTable(storage: storage, selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(caret, 6, "Caret lands in the first header cell")
        let expected = """
        Hello

        |  |  |  |
        | :--- | :--- | :--- |
        |  |  |  |

        """
        XCTAssertEqual(serialize(storage), expected)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testInsertTableInsideTableGoesAfterIt() {
        let storage = makeStorage(table)
        let caret = TableController.insertTable(storage: storage, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(TableController.models(in: storage).count, 2, "A second, separate table")
        XCTAssertEqual(caret, 15, "After the first table (and its new separator)")
        let expected = table + "\n\n" + """
        |  |  |  |
        | :--- | :--- | :--- |
        |  |  |  |

        """
        XCTAssertEqual(serialize(storage), expected)
        let reparsed = NSTextStorage()
        reparsed.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(serialize(storage))))
        XCTAssertEqual(TableController.models(in: reparsed).count, 2)
    }

    // MARK: - Tab navigation

    func testTabNavigationRowMajor() {
        // "H1\nH2\nH3\na\nb\nc": cell content ends at 2, 5, 8, 10, 12, 14.
        let storage = makeStorage(table)
        var caret = 0
        for expected in [5, 8, 10, 12, 14] {
            let result = EditingBehavior.indent(in: context(storage, at: caret))
            XCTAssertEqual(result?.selection.location, expected, "Tab to next cell")
            XCTAssertEqual(result?.mutated, false)
            caret = expected
        }
        // Shift-Tab walks back.
        for expected in [12, 10, 8, 5, 2] {
            let result = EditingBehavior.outdent(in: context(storage, at: caret))
            XCTAssertEqual(result?.selection.location, expected, "Shift-Tab to previous cell")
            XCTAssertEqual(result?.mutated, false)
            caret = expected
        }
        // Shift-Tab in the first cell is swallowed.
        let result = EditingBehavior.outdent(in: context(storage, at: caret))
        XCTAssertEqual(result?.selection.location, 2)
        XCTAssertEqual(result?.mutated, false)
        XCTAssertEqual(storage.string, "H1\nH2\nH3\na\nb\nc")
    }

    func testTabInLastCellAppendsRow() {
        let storage = makeStorage(table)
        let result = EditingBehavior.indent(in: context(storage, at: 13))
        XCTAssertEqual(result?.mutated, true)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.cells.count, 9)
        for cell in model.cellsInRow(2) {
            XCTAssertFalse(cell.isHeader)
            XCTAssertEqual(cell.block.startingRow, 2)
        }
        XCTAssertEqual(result?.selection.location, 15, "Caret into the new row's first cell")
        let expected = """
        | H1 | H2 | H3 |
        | --- | --- | --- |
        | a | b | c |
        |  |  |  |

        """
        XCTAssertEqual(serialize(storage), expected)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testTabAppendedRowIsUndoable() {
        let storage = makeStorage(table)
        let undoManager = UndoManager()
        let result = EditingBehavior.indent(in: context(storage, at: 13, undoManager: undoManager))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(model(storage).rowCount, 3)
        undoManager.undo()
        XCTAssertEqual(model(storage).rowCount, 2)
        XCTAssertEqual(storage.string, "H1\nH2\nH3\na\nb\nc")
        undoManager.redo()
        XCTAssertEqual(model(storage).rowCount, 3)
    }

    func testTabOutsideTableKeepsListBehavior() {
        // Storage text: "item".
        let storage = makeStorage("- item")
        let result = EditingBehavior.indent(in: context(storage, at: 2))
        XCTAssertEqual(result?.mutated, true, "List indent still works")
        let lists = (storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle)?.textLists
        XCTAssertEqual(lists?.count, 2, "Tab nested the list item")
    }

    // MARK: - Row operations

    func testInsertRowBelow() {
        let storage = makeStorage(table)
        // Caret in "b" (index 11).
        let caret = TableController.insertRow(above: false, storage: storage, selection: NSRange(location: 11, length: 0))
        XCTAssertEqual(caret, 15)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.cellsInRow(2).count, 3)
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | --- | --- |
        | a | b | c |
        |  |  |  |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testInsertRowAboveShiftsIndices() {
        let storage = makeStorage(table3)
        // Caret in "d" (index 15): insert above the second body row.
        let caret = TableController.insertRow(above: true, storage: storage, selection: NSRange(location: 15, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 4)
        XCTAssertEqual(model.cellsInRow(2).map(\.block.startingRow), [2, 2, 2])
        // The old second body row is now row 3.
        XCTAssertEqual(model.cellsInRow(3).map(\.block.startingRow), [3, 3, 3])
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | --- | --- |
        | a | b | c |
        |  |  |  |
        | d | e | f |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testInsertRowBelowDocumentFinalTable() {
        // The table ends the document: the last cell has no trailing newline.
        let storage = makeStorage(table)
        XCTAssertFalse(storage.string.hasSuffix("\n"))
        let caret = TableController.insertRow(above: false, storage: storage, selection: NSRange(location: 13, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.cells.count, 9, "All three new cells must exist as paragraphs")
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | --- | --- |
        | a | b | c |
        |  |  |  |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testDeleteRow() {
        let storage = makeStorage(table3)
        // Caret in "b": delete the first body row.
        let caret = TableController.deleteRow(storage: storage, selection: NSRange(location: 11, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.cells.count, 6)
        // The old second body row shifted up.
        XCTAssertEqual(model.cellsInRow(1).map(\.block.startingRow), [1, 1, 1])
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | --- | --- |
        | d | e | f |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testDeleteDocumentFinalRow() {
        // Deleting the last row of a document-final table takes the preceding
        // separator instead of a trailing one.
        let storage = makeStorage(table)
        let caret = TableController.deleteRow(storage: storage, selection: NSRange(location: 11, length: 0))
        XCTAssertNotNil(caret)
        XCTAssertEqual(storage.string, "H1\nH2\nH3")
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | --- | --- |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testDeleteHeaderRowPrevented() {
        let storage = makeStorage(table)
        let before = storage.string
        let caret = TableController.deleteRow(storage: storage, selection: NSRange(location: 4, length: 0))
        XCTAssertNil(caret, "The header row cannot be deleted")
        XCTAssertEqual(storage.string, before)
        XCTAssertEqual(model(storage).rowCount, 2)
    }

    func testDeleteLastBodyRowLeavesHeaderOnlyTable() {
        // A header-only table reparses as a table (verified with
        // swift-markdown), so deleting the last body row is allowed.
        let storage = makeStorage(table)
        let caret = TableController.deleteRow(storage: storage, selection: NSRange(location: 9, length: 0))
        XCTAssertNotNil(caret)
        XCTAssertEqual(model(storage).rowCount, 1)
        let serialized = serialize(storage)
        XCTAssertEqual(serialized, """
        | H1 | H2 | H3 |
        | --- | --- | --- |

        """)
        let reparsed = MarkdownParser.parse(serialized)
        XCTAssertTrue(reparsed.document.children.contains { $0 is Markdown.Table })
    }

    // MARK: - Column operations

    func testInsertColumnRight() {
        let storage = makeStorage(table)
        // Caret in "H1" (column 0).
        let caret = TableController.insertColumn(left: false, storage: storage, selection: NSRange(location: 0, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.columnCount, 4)
        XCTAssertEqual(model.table.numberOfColumns, 4)
        XCTAssertEqual(model.cells.count, 8)
        // Old columns 1–2 shifted to 2–3.
        XCTAssertEqual(model.cell(row: 0, column: 2)?.block.startingColumn, 2)
        XCTAssertEqual(model.cell(row: 0, column: 2).map { String(storage.string[Range($0.contentRange, in: storage.string)!]) }, "H2")
        XCTAssertEqual(model.alignments, ["", "", "", ""], "New column gets an empty alignment entry")
        XCTAssertEqual(serialize(storage), """
        | H1 |  | H2 | H3 |
        | --- | --- | --- | --- |
        | a |  | b | c |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testInsertColumnLeft() {
        let storage = makeStorage(table)
        // Caret in "b" (column 1).
        let caret = TableController.insertColumn(left: true, storage: storage, selection: NSRange(location: 11, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.columnCount, 4)
        // New header cell in the inserted column is marked header too.
        XCTAssertEqual(model.cell(row: 0, column: 1)?.isHeader, true)
        XCTAssertEqual(serialize(storage), """
        | H1 |  | H2 | H3 |
        | --- | --- | --- | --- |
        | a |  | b | c |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testInsertColumnRightOfLastColumnAtDocumentEnd() {
        let storage = makeStorage(table)
        // Caret in "c" (last column, unterminated document-final cell).
        let caret = TableController.insertColumn(left: false, storage: storage, selection: NSRange(location: 13, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.columnCount, 4)
        XCTAssertEqual(model.cells.count, 8, "All new cells must exist as paragraphs")
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |  |
        | --- | --- | --- | --- |
        | a | b | c |  |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testDeleteColumn() {
        let storage = makeStorage(table)
        // Caret in "b" (column 1).
        let caret = TableController.deleteColumn(storage: storage, selection: NSRange(location: 11, length: 0))
        XCTAssertNotNil(caret)
        let model = model(storage)
        XCTAssertEqual(model.columnCount, 2)
        XCTAssertEqual(model.table.numberOfColumns, 2)
        XCTAssertEqual(model.cells.count, 4)
        // Old column 2 shifted to 1.
        XCTAssertEqual(model.cell(row: 0, column: 1)?.block.startingColumn, 1)
        XCTAssertEqual(model.alignments, ["", ""], "Deleted column's alignment entry removed")
        XCTAssertEqual(serialize(storage), """
        | H1 | H3 |
        | --- | --- |
        | a | c |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testDeleteLastColumnPrevented() {
        let storage = makeStorage("""
        | A |
        | --- |
        | x |
        """)
        let before = storage.string
        let caret = TableController.deleteColumn(storage: storage, selection: NSRange(location: 2, length: 0))
        XCTAssertNil(caret, "The last remaining column cannot be deleted")
        XCTAssertEqual(storage.string, before)
    }

    // MARK: - Alignment cycling

    func testCycleAlignment() {
        let storage = makeStorage(table)
        // Caret in "b" (column 1): "" → left → center → right → left.
        XCTAssertTrue(TableController.cycleAlignment(storage: storage, selection: NSRange(location: 11, length: 0)))
        XCTAssertEqual(model(storage).alignments, ["", "left", ""])
        XCTAssertTrue(TableController.cycleAlignment(storage: storage, selection: NSRange(location: 11, length: 0)))
        XCTAssertEqual(model(storage).alignments, ["", "center", ""])
        XCTAssertTrue(TableController.cycleAlignment(storage: storage, selection: NSRange(location: 11, length: 0)))
        XCTAssertEqual(model(storage).alignments, ["", "right", ""])
        XCTAssertEqual(serialize(storage), """
        | H1 | H2 | H3 |
        | --- | ---: | --- |
        | a | b | c |

        """)
        XCTAssertTrue(TableController.cycleAlignment(storage: storage, selection: NSRange(location: 11, length: 0)))
        XCTAssertEqual(model(storage).alignments, ["", "left", ""])
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
        // Every cell paragraph carries the same array.
        for cell in model(storage).cells {
            let alignments = storage.attribute(MDAttr.tableAlignments, at: cell.range.location, effectiveRange: nil) as? [String]
            XCTAssertEqual(alignments, ["", "left", ""])
        }
        // Outside a table: no-op.
        let plain = makeStorage("Hello")
        XCTAssertFalse(TableController.cycleAlignment(storage: plain, selection: NSRange(location: 1, length: 0)))
    }

    // MARK: - Return / multi-line cells

    func testReturnInCellStaysOneParagraph() {
        let storage = makeStorage(table)
        // Caret mid-"H1" (index 1).
        let result = EditingBehavior.insertNewline(in: context(storage, at: 1))
        XCTAssertEqual(result?.mutated, true)
        XCTAssertEqual(storage.string, "H\u{2028}1\nH2\nH3\na\nb\nc")
        let model = model(storage)
        XCTAssertEqual(model.cells.count, 6, "Still one paragraph per cell")
        XCTAssertEqual(model.cellsInRow(0).count, 3)
        // A U+2028 inside a cell serializes as a space.
        XCTAssertEqual(serialize(storage), """
        | H 1 | H2 | H3 |
        | --- | --- | --- |
        | a | b | c |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    // MARK: - Backspace / forward delete at table boundaries

    func testBackspaceAtCellStartSwallowed() {
        let storage = makeStorage(table)
        // Start of "H2" (index 3) and of the first body cell "a" (index 9).
        for location in [3, 9] {
            let result = EditingBehavior.deleteBackward(in: context(storage, at: location))
            XCTAssertNotNil(result, "Handled (swallowed) at cell start")
            XCTAssertEqual(result?.mutated, false)
        }
        XCTAssertEqual(storage.string, "H1\nH2\nH3\na\nb\nc")
        XCTAssertEqual(model(storage).cells.count, 6)
    }

    func testBackspaceAfterTableSwallowed() {
        // Storage text: cells + "After".
        let storage = makeStorage(table + "\n\nAfter")
        let location = storage.string.count - 5
        let result = EditingBehavior.deleteBackward(in: context(storage, at: location))
        XCTAssertEqual(result?.mutated, false, "Backspace after a table must not merge into the last cell")
        XCTAssertEqual(model(storage).cells.count, 6)
    }

    func testDeleteForwardAtCellEndSwallowed() {
        let storage = makeStorage(table)
        // End of "H1" (index 2) and end of "H3" (index 8).
        for location in [2, 8] {
            let result = EditingBehavior.deleteForward(in: context(storage, at: location))
            XCTAssertNotNil(result, "Handled (swallowed) at cell end")
            XCTAssertEqual(result?.mutated, false)
        }
        // Mid-cell falls through to the default.
        XCTAssertNil(EditingBehavior.deleteForward(in: context(storage, at: 1)))
        XCTAssertEqual(storage.string, "H1\nH2\nH3\na\nb\nc")
    }

    func testDeleteForwardBeforeTableSwallowed() {
        // Storage text: "Intro" + cells.
        let storage = makeStorage("Intro\n\n" + table)
        let result = EditingBehavior.deleteForward(in: context(storage, at: 5))
        XCTAssertEqual(result?.mutated, false, "Forward delete before a table must not pull in the first cell")
        XCTAssertEqual(model(storage).cells.count, 6)
        // Mid-paragraph falls through.
        XCTAssertNil(EditingBehavior.deleteForward(in: context(storage, at: 0)))
    }

    // MARK: - Whole-table deletion and defensive cleanup

    func testWholeTableDeleteLeavesNoOrphans() {
        // Storage text: "Before" + cells + "After".
        let storage = makeStorage("Before\n\n" + table + "\n\nAfter")
        let model = model(storage)
        storage.deleteCharacters(in: model.range)
        TableController.sanitize(storage: storage, around: NSRange(location: 6, length: 0))
        XCTAssertTrue(TableController.models(in: storage).isEmpty, "No orphan cell paragraphs remain")
        XCTAssertEqual(serialize(storage), "Before\n\nAfter\n")
    }

    func testSanitizeAfterHeaderRowDeletedRaw() {
        // Simulates a selection deletion that removes the header row's cells.
        let storage = makeStorage(table)
        storage.deleteCharacters(in: NSRange(location: 0, length: 9)) // "H1\nH2\nH3\n"
        TableController.sanitize(storage: storage, around: NSRange(location: 0, length: 0))
        let model = model(storage)
        XCTAssertEqual(model.cells.map(\.block.startingRow), [0, 0, 0], "Rows renumbered densely")
        XCTAssertEqual(model.cells.map(\.isHeader), [true, true, true], "First row promoted to header")
        XCTAssertEqual(serialize(storage), """
        | a | b | c |
        | --- | --- | --- |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    func testSanitizeAfterSingleColumnDeletedRaw() {
        // Simulates a selection deletion that removes one column's cells
        // ("H2\n" and "b\n"), leaving a hole in the column indices.
        let storage = makeStorage(table)
        storage.deleteCharacters(in: NSRange(location: 11, length: 2))
        storage.deleteCharacters(in: NSRange(location: 3, length: 3))
        TableController.sanitize(storage: storage, around: NSRange(location: 3, length: 0))
        let model = model(storage)
        XCTAssertEqual(model.columnCount, 2)
        XCTAssertEqual(model.cells.map(\.block.startingColumn), [0, 1, 0, 1], "Columns renumbered densely")
        XCTAssertEqual(model.table.numberOfColumns, 2)
        XCTAssertEqual(serialize(storage), """
        | H1 | H3 |
        | --- | --- |
        | a | c |

        """)
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    // MARK: - Model lookup

    func testModelLookup() throws {
        // Storage text: "Intro" + cells + "Outro".
        let storage = makeStorage("Intro\n\n" + table + "\n\nOutro")
        XCTAssertNil(TableController.model(at: 0, in: storage), "Body text is not in a table")
        XCTAssertNotNil(TableController.model(at: 8, in: storage))
        XCTAssertNil(TableController.model(at: storage.length - 1, in: storage))
        let model = try XCTUnwrap(TableController.model(at: 9, in: storage))
        let cell = try XCTUnwrap(TableController.cell(at: 9, in: model))
        XCTAssertEqual(cell.block.startingColumn, 1)
        XCTAssertNil(TableController.model(at: 0, in: makeStorage()))
    }

    // MARK: - Document-final empty cell preservation

    func testDocumentFinalEmptyCellSurvivesBuild() {
        // A document ending in an empty cell: the builder must keep the
        // cell's (otherwise character-less) paragraph.
        let source = """
        | A | B |
        | --- | --- |
        | x |  |
        """
        let storage = makeStorage(source)
        let model = model(storage)
        XCTAssertEqual(model.cells.count, 4, "The trailing empty cell must not vanish")
        XCTAssertEqual(model.cellsInRow(1).count, 2)
        XCTAssertEqual(serialize(storage), source + "\n")
        XCTAssertEqual(roundTrip(source + "\n"), source + "\n")
    }
}
