import XCTest
@testable import MDEditor

/// PDF generation from a text storage (the panel and print flows are manual
/// QA — see TESTING.md). Creates real views, so it runs on the main actor.
@MainActor
final class PDFExportTests: XCTestCase {
    /// parse → build → styled storage (no live layout stack attached).
    private func styledStorage(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        return storage
    }

    func testPDFDataIsNonEmptyAndValid() {
        let storage = styledStorage("# Title\n\nSome **bold** body text.\n\n- item")
        let data = PDFExport.pdfData(from: storage)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 200)
        XCTAssertTrue(data?.starts(with: Array("%PDF-".utf8)) ?? false, "valid PDF header")
    }

    /// Tables, rules, quotes and code render off-screen too (smoke).
    func testPDFDataWithComplexContent() {
        let storage = styledStorage("""
        # T

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ---

        > quote

        ```
        code
        ```
        """)
        XCTAssertNotNil(PDFExport.pdfData(from: storage))
    }

    func testEmptyStorageYieldsNil() {
        XCTAssertNil(PDFExport.pdfData(from: NSTextStorage()))
    }

    /// The printable view is framed to the content, not the placeholder size.
    func testPrintableViewFitsContent() {
        let storage = styledStorage("one line")
        let view = PDFExport.printableView(from: storage, textWidth: 400)
        XCTAssertGreaterThan(view.frame.height, 16)
        XCTAssertEqual(view.frame.width, 440) // text width + the editor insets
    }
}
