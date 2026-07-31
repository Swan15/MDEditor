import XCTest
@testable import MDEditor

/// Pasteboard image classification: which flavors count as images and in
/// what precedence — the logic level of the paste/drop image pipeline.
final class ImagePasteboardTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MDEditorTests-\(UUID().uuidString)"))
    }

    private var pngData: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Flavor precedence (pure)

    func testPreferredImageDataTypePrefersPNGOverTIFF() {
        XCTAssertEqual(
            ImagePasteboard.preferredImageDataType(from: [.tiff, .png, .string]),
            .png
        )
        XCTAssertEqual(ImagePasteboard.preferredImageDataType(from: [.tiff, .string]), .tiff)
        XCTAssertNil(ImagePasteboard.preferredImageDataType(from: [.string, .html]))
        XCTAssertNil(ImagePasteboard.preferredImageDataType(from: []))
    }

    func testIsImageFile() {
        XCTAssertTrue(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b.png")))
        XCTAssertTrue(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b.JPG")))
        XCTAssertTrue(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b.heic")))
        XCTAssertFalse(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b.txt")))
        XCTAssertFalse(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b.md")))
        XCTAssertFalse(ImagePasteboard.isImageFile(URL(fileURLWithPath: "/a/b")))
    }

    // MARK: - Pasteboard reads

    /// The precedence guarantee: a pasteboard carrying BOTH an image flavor
    /// and Markdown-looking text must be treated as an image paste. (The
    /// editor checks `ImagePasteboard.imageContent` before the Markdown
    /// conversion; this pins that the classifier fires — and that the
    /// Markdown conversion would itself have deferred anyway.)
    func testImageFlavorWinsOverMarkdownText() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(pngData, forType: .png)
        pasteboard.setString("# Heading\n\n- a list", forType: .string)
        guard case .data = ImagePasteboard.imageContent(from: pasteboard) else {
            return XCTFail("expected image data content")
        }
        XCTAssertNil(PasteConversion.markdownToConvert(from: pasteboard),
                     "rich flavors already veto Markdown conversion")
    }

    func testPlainMarkdownTextYieldsNoImageContent() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("# Heading", forType: .string)
        XCTAssertNil(ImagePasteboard.imageContent(from: pasteboard))
        XCTAssertNotNil(PasteConversion.markdownToConvert(from: pasteboard),
                        "text-only paste still goes through Markdown conversion")
    }

    func testImageFileURLIsPreferred() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorPasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("drag me.png")
        try pngData.write(to: file)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        guard case .file(let url) = ImagePasteboard.imageContent(from: pasteboard) else {
            return XCTFail("expected file content")
        }
        XCTAssertEqual(url.lastPathComponent, "drag me.png")
    }

    func testNonImageFileURLIsNotImageContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorPasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        XCTAssertNil(ImagePasteboard.imageContent(from: pasteboard))
    }
}
