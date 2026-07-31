import XCTest
@testable import MDEditor

/// Table layout/render regression tests against the app's TextKit 1 stack.
///
/// The Phase 4 spike established that TextKit 2 cannot lay out `NSTextTable`
/// (cell paragraphs stack full-width, no grid, no borders), which is why the
/// editor uses a classic `NSLayoutManager` stack. These tests pin the facts
/// that matter: cell paragraphs tile into a grid under TK1, the style
/// engine's chrome (gridlines, padding, header shading, column alignment) is
/// applied, and the rendered output can be captured to a PNG for manual QA.
/// A tripwire test keeps documenting the TK2 behavior — if a future macOS
/// fixes TextKit 2 tables, that test fails and the TK1 decision can be
/// revisited.
@MainActor
final class TableRenderTests: XCTestCase {

    /// The editor's TextKit 1 stack, offscreen at a fixed width.
    private struct Stack {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    private let tableMarkdown = """
    Intro.

    | Name | Age | Notes |
    | --- | :---: | --- |
    | Alice | 30 | **Bold** note |
    | Bob | 25 | A much longer note that should wrap onto several lines inside its narrow table cell |

    Outro.
    """

    private func makeStack(_ markdown: String, width: CGFloat = 600) -> Stack {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        return Stack(storage: storage, layoutManager: layoutManager, container: container)
    }

    /// Bounding rect of a cell paragraph's glyphs under TK1.
    private func frame(of range: NSRange, in stack: Stack) -> CGRect {
        let glyphRange = stack.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return stack.layoutManager.boundingRect(forGlyphRange: glyphRange, in: stack.container)
    }

    /// Groups sorted coordinates within `tolerance` of each other.
    private func clusters(_ values: [CGFloat], tolerance: CGFloat = 3) -> [[CGFloat]] {
        var result: [[CGFloat]] = []
        for value in values.sorted() {
            if let last = result.indices.last, value - result[last].last! <= tolerance {
                result[last].append(value)
            } else {
                result.append([value])
            }
        }
        return result
    }

    /// Maps each frame's horizontal center to a column band index (0-based).
    /// Center-based because glyph bounds shift with column alignment (a
    /// centered cell's text doesn't start at the cell's left edge).
    private func columnBands(_ frames: [CGRect], columnCount: Int) -> [Int] {
        guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max(), maxX > minX else {
            return []
        }
        let bandWidth = (maxX - minX) / CGFloat(columnCount)
        return frames.map { frame in
            min(columnCount - 1, max(0, Int((frame.midX - minX) / bandWidth)))
        }
    }

    /// Asserts the cells tile into `columnCount` columns and `rowCount` rows.
    private func assertGrid(_ model: TableController.Model, in stack: Stack, file: StaticString = #filePath, line: UInt = #line) {
        let frames = model.cells.map { frame(of: $0.range, in: stack) }
        let yClusters = clusters(frames.map(\.minY))
        XCTAssertEqual(yClusters.count, model.rowCount, "Cells should tile into rows", file: file, line: line)
        let bands = columnBands(frames, columnCount: model.columnCount)
        for (cell, band) in zip(model.cells, bands) {
            XCTAssertEqual(band, cell.column, "Cell (\(cell.row),\(cell.column)) in wrong column band", file: file, line: line)
        }
        // Row-major geometry: lower rows sit below upper rows.
        for (cell, frame) in zip(model.cells, frames) where cell.row > 0 {
            if let above = model.cell(row: cell.row - 1, column: cell.column) {
                XCTAssertGreaterThan(frame.minY, self.frame(of: above.range, in: stack).minY,
                                     file: file, line: line)
            }
        }
    }

    // MARK: - Grid tiling under TextKit 1

    func testCellsTileIntoGrid() throws {
        let stack = makeStack(tableMarkdown)
        stack.layoutManager.ensureLayout(for: stack.container)
        guard let model = TableController.models(in: stack.storage).first else {
            return XCTFail("No table found")
        }
        XCTAssertEqual(model.cells.count, 9)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.columnCount, 3)

        let frames = model.cells.map { frame(of: $0.range, in: stack) }
        guard frames.allSatisfy({ !$0.isEmpty }) else {
            throw XCTSkip("Offscreen layout produced no glyph bounds")
        }
        assertGrid(model, in: stack)
        // The wrapping cell makes its row taller than one line.
        let longCell = try XCTUnwrap(model.cell(row: 2, column: 2))
        XCTAssertGreaterThan(frame(of: longCell.range, in: stack).height, 20)
    }

    // MARK: - Style engine chrome

    func testChromeApplied() throws {
        let stack = makeStack(tableMarkdown)
        let model = try XCTUnwrap(TableController.models(in: stack.storage).first)

        for cell in model.cells {
            // Gridlines and padding on every cell block…
            XCTAssertEqual(cell.block.borderColor(for: .minX), StyleEngine.tableGridColor)
            XCTAssertEqual(cell.block.borderColor(for: .maxY), StyleEngine.tableGridColor)
            XCTAssertEqual(cell.block.width(for: .padding, edge: .minX), StyleEngine.tableCellPadding)
            // …and on the table itself.
            XCTAssertEqual(model.table.borderColor(for: .minX), StyleEngine.tableGridColor)
            XCTAssertFalse(model.table.hidesEmptyCells)

            let attributes = stack.storage.attributes(at: cell.range.location, effectiveRange: nil)
            let style = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
            if cell.isHeader {
                // Header row: shading + faux-bold stroke (never a bold font).
                XCTAssertEqual(cell.block.backgroundColor, StyleEngine.tableHeaderBackground)
                XCTAssertEqual(attributes[.strokeWidth] as? CGFloat, StyleEngine.tableHeaderStroke)
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                XCTAssertFalse(traits.contains(.bold), "Header must not use a real bold font")
            } else {
                XCTAssertEqual(cell.block.backgroundColor, .clear)
                XCTAssertNil(attributes[.strokeWidth])
            }
            // Column alignment from mdTableAlignments ("Age" is centered).
            if cell.column == 1 {
                XCTAssertEqual(style.alignment, .center)
            } else {
                XCTAssertEqual(style.alignment, .natural)
            }
        }
        // No table spacing above/below cell paragraphs.
        let style = stack.storage.attribute(.paragraphStyle, at: model.cells[0].range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacing, 0)
    }

    // MARK: - Structure edit + relayout

    /// A controller structure op (insert row) retiles the grid under TK1.
    func testInsertRowRetilesGrid() throws {
        let stack = makeStack(tableMarkdown)
        stack.layoutManager.ensureLayout(for: stack.container)
        let model = try XCTUnwrap(TableController.models(in: stack.storage).first)
        let anchor = try XCTUnwrap(model.cell(row: 2, column: 0))
        let caret = TableController.insertRow(
            above: false, storage: stack.storage, selection: NSRange(location: anchor.range.location, length: 0)
        )
        XCTAssertNotNil(caret)
        stack.layoutManager.ensureLayout(for: stack.container)
        let updated = try XCTUnwrap(TableController.models(in: stack.storage).first)
        XCTAssertEqual(updated.rowCount, 4)
        XCTAssertEqual(updated.cells.count, 12)
        let frames = updated.cells.map { frame(of: $0.range, in: stack) }
        guard frames.allSatisfy({ !$0.isEmpty }) else {
            throw XCTSkip("Offscreen layout produced no glyph bounds")
        }
        assertGrid(updated, in: stack)
    }

    // MARK: - PNG render (manual QA artifact)

    /// Renders the table (backgrounds, borders, glyphs) to a PNG.
    func testRenderTableToPNG() throws {
        let stack = makeStack(tableMarkdown)
        stack.layoutManager.ensureLayout(for: stack.container)
        let glyphRange = stack.layoutManager.glyphRange(for: stack.container)
        let used = stack.layoutManager.usedRect(for: stack.container)
        guard !used.isEmpty, glyphRange.length > 0 else {
            throw XCTSkip("Offscreen layout unavailable")
        }
        let size = NSSize(width: ceil(used.width) + 2, height: ceil(used.height) + 2)
        // Draw into a flipped image context: NSLayoutManager sets its text
        // matrix from the context's flippedness, so a raw (unflipped) bitmap
        // context renders glyphs mirrored.
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        if let cgContext = NSGraphicsContext.current?.cgContext {
            cgContext.setFillColor(NSColor.white.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))
        }
        stack.layoutManager.drawBackground(forGlyphRange: glyphRange, at: CGPoint(x: 1, y: 1))
        stack.layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: 1, y: 1))
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let preferred = URL(fileURLWithPath: "/tmp/mdeditor-table-render.png")
        do {
            try data.write(to: preferred)
            print("RENDER-PNG-PATH: \(preferred.path)")
        } catch {
            // The sandboxed test host may not write to /tmp.
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mdeditor-table-render.png")
            try data.write(to: fallback)
            print("RENDER-PNG-PATH: \(fallback.path)")
        }
    }

    // MARK: - TextKit 2 tripwire

    /// Documents why the editor uses TextKit 1: TextKit 2 has no table
    /// layout — cell paragraphs stack full-width (single x cluster), no grid,
    /// no borders. If a future macOS implements tables in TextKit 2, this
    /// test fails; that's the cue to revisit the stack decision.
    func testTextKit2IgnoresTableGeometry() throws {
        let storage = NSTextStorage()
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(tableMarkdown)))
        StyleEngine.styleAll(storage)
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        let model = try XCTUnwrap(TableController.models(in: storage).first)
        var minYs: [CGFloat] = []
        var frames: [CGRect] = []
        for cell in model.cells {
            guard let location = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: cell.range.location
            ), let fragment = layoutManager.textLayoutFragment(for: location) else {
                throw XCTSkip("Offscreen TextKit 2 layout produced no fragments")
            }
            minYs.append(fragment.layoutFragmentFrame.minY)
            frames.append(fragment.layoutFragmentFrame)
        }
        print("TRIPWIRE-TK2: frames=\(frames)")
        // The signature of "no table layout": every cell on its own line
        // (x positions are unusable — centered cells shift horizontally).
        XCTAssertEqual(clusters(minYs).count, model.cells.count,
                       "TextKit 2 laid table cells out in rows — revisit the TextKit 1 decision")
    }
}
