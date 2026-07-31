import XCTest
@testable import MDEditor

/// Validates the test pipeline itself; real coverage starts in Phase 1.
final class SmokeTests: XCTestCase {
    func testDocumentTitleFallback() {
        XCTAssertEqual(DocumentModel().title, "Untitled")
    }

    func testDocumentTitleFromFileURL() {
        let doc = DocumentModel()
        doc.fileURL = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertEqual(doc.title, "notes.md")
    }
}
