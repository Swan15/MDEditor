import AppKit
import XCTest
@testable import MDEditor

/// Quick Look thumbnail rendering: a white page with styled text for real
/// documents, nil for blank content or degenerate sizes, capped input for
/// huge files.
final class ThumbnailRenderTests: XCTestCase {
    private func bitmap(of image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func darkPixelCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y),
                   color.redComponent < 0.5, color.greenComponent < 0.5, color.blueComponent < 0.5 {
                    count += 1
                }
            }
        }
        return count
    }

    func testRenderProducesWhitePageWithDarkText() throws {
        let markdown = """
        # Meeting Notes

        Some **bold** and *italic* body text.

        - one
        - two

        `code` and a [link](https://example.com).
        """
        let size = CGSize(width: 512, height: 512)
        let image = try XCTUnwrap(MarkdownThumbnailImage.render(markdown: markdown, size: size))
        XCTAssertEqual(image.size, size)

        let rep = try bitmap(of: image)
        XCTAssertEqual(rep.pixelsWide, 512)
        XCTAssertEqual(rep.pixelsHigh, 512)
        // White page background (the corners sit outside the text inset).
        for (x, y) in [(4, 4), (508, 4), (4, 508), (508, 508)] {
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y), "corner pixel \(x),\(y)")
            XCTAssertGreaterThan(color.redComponent, 0.9, "corner \(x),\(y) should be page-white")
            XCTAssertGreaterThan(color.greenComponent, 0.9, "corner \(x),\(y) should be page-white")
            XCTAssertGreaterThan(color.blueComponent, 0.9, "corner \(x),\(y) should be page-white")
        }
        XCTAssertGreaterThan(darkPixelCount(rep), 200, "the rendered text must be visible")
    }

    func testHeadingOnlyDocumentRenders() throws {
        let image = try XCTUnwrap(MarkdownThumbnailImage.render(
            markdown: "# Just a Title", size: CGSize(width: 256, height: 256)
        ))
        XCTAssertGreaterThan(darkPixelCount(try bitmap(of: image)), 50)
    }

    func testBlankDocumentsReturnNil() {
        let size = CGSize(width: 256, height: 256)
        XCTAssertNil(MarkdownThumbnailImage.render(markdown: "", size: size))
        XCTAssertNil(MarkdownThumbnailImage.render(markdown: "  \n\n \t ", size: size))
    }

    func testDegenerateSizesReturnNil() {
        XCTAssertNil(MarkdownThumbnailImage.render(markdown: "text", size: .zero))
        XCTAssertNil(MarkdownThumbnailImage.render(markdown: "text", size: CGSize(width: 4, height: 4)))
    }

    /// Huge files render the first page without parsing megabytes.
    func testHugeSourceIsCappedAndStillRenders() throws {
        let paragraph = "The quick brown fox jumps over the lazy dog. "
        let markdown = String(repeating: paragraph + "\n\n", count: 5000) // ~230 KB
        XCTAssertGreaterThan(markdown.utf8.count, MarkdownThumbnailImage.maximumSourceLength)
        let image = try XCTUnwrap(MarkdownThumbnailImage.render(
            markdown: markdown, size: CGSize(width: 256, height: 256)
        ))
        XCTAssertGreaterThan(darkPixelCount(try bitmap(of: image)), 200)
    }
}
