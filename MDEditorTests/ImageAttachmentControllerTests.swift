import XCTest
@testable import MDEditor

/// Image loading, scaling, placeholders and alt-text editing — all headless,
/// through `ImageAttachmentController` and the serializer.
final class ImageAttachmentControllerTests: XCTestCase {
    private func makeStorage(_ markdown: String = "") -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Real image bytes without touching the screen.
    private func makeImageData(width: Int, height: Int, type: NSBitmapImageRep.FileType = .png) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: type, properties: [:])!
    }

    /// Temp doc with `assets/pic.png` (8×6) on disk.
    private func makeDocumentWithAsset(markdown: String = "![p](assets/pic.png)") throws -> (dir: URL, storage: NSTextStorage) {
        let dir = try makeTempDir()
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try makeImageData(width: 8, height: 6).write(to: assets.appendingPathComponent("pic.png"))
        return (dir, makeStorage(markdown))
    }

    // MARK: - Scaling math

    func testDisplaySizeScalesDownToAvailableWidth() {
        let size = ImageAttachmentController.displaySize(
            natural: NSSize(width: 1000, height: 500), availableWidth: 400, maxHeight: 640
        )
        XCTAssertEqual(size.width, 400, accuracy: 0.01)
        XCTAssertEqual(size.height, 200, accuracy: 0.01)
    }

    func testDisplaySizeNeverUpscales() {
        let size = ImageAttachmentController.displaySize(
            natural: NSSize(width: 200, height: 100), availableWidth: 400, maxHeight: 640
        )
        XCTAssertEqual(size.width, 200, accuracy: 0.01)
        XCTAssertEqual(size.height, 100, accuracy: 0.01)
    }

    func testDisplaySizeHeightCapPreservesAspect() {
        let size = ImageAttachmentController.displaySize(
            natural: NSSize(width: 1000, height: 2000), availableWidth: 800, maxHeight: 300
        )
        XCTAssertEqual(size.height, 300, accuracy: 0.01)
        XCTAssertEqual(size.width, 150, accuracy: 0.01)
    }

    func testDisplaySizeZeroNaturalIsDegenerateButSafe() {
        let size = ImageAttachmentController.displaySize(
            natural: .zero, availableWidth: 400, maxHeight: 640
        )
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - Attachment bounds (layout-facing)

    func testAttachmentBoundsScaleToLineFragmentWidth() {
        let attachment = MDImageAttachment(source: "x.png", altText: "", title: nil)
        attachment.image = NSImage(size: NSSize(width: 1000, height: 500))
        attachment.naturalSize = NSSize(width: 1000, height: 500)
        let bounds = attachment.attachmentBounds(
            for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 400, height: 14),
            glyphPosition: .zero, characterIndex: 0
        )
        // 1pt slack under the fragment width (anti wrap-thrash).
        XCTAssertEqual(bounds.width, 399, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 199.5, accuracy: 0.01)
    }

    func testAttachmentBoundsRespectHeightCap() {
        let attachment = MDImageAttachment(source: "x.png", altText: "", title: nil)
        attachment.image = NSImage(size: NSSize(width: 1000, height: 2000))
        attachment.naturalSize = NSSize(width: 1000, height: 2000)
        attachment.maxDisplayHeight = 300
        let bounds = attachment.attachmentBounds(
            for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 1000, height: 14),
            glyphPosition: .zero, characterIndex: 0
        )
        XCTAssertEqual(bounds.height, 300, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 150, accuracy: 0.01)
    }

    // MARK: - Loading

    func testLoadsLocalImageRelativeToDocument() throws {
        let (dir, storage) = try makeDocumentWithAsset()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = ImageAttachmentController.loadImages(
            in: storage, documentURL: dir.appendingPathComponent("doc.md"), scope: nil
        )
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.loadedAny)
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertFalse(found.attachment.isPlaceholder)
        XCTAssertNotNil(found.attachment.image)
        XCTAssertEqual(found.attachment.naturalSize?.width ?? 0, 8, accuracy: 0.1)
        XCTAssertEqual(found.attachment.naturalSize?.height ?? 0, 6, accuracy: 0.1)
        XCTAssertEqual(found.attachment.source, "assets/pic.png")
    }

    func testMissingFileBecomesPlaceholderAndKeepsSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = makeStorage("![gone](assets/gone.png)")
        let report = ImageAttachmentController.loadImages(
            in: storage, documentURL: dir.appendingPathComponent("doc.md"), scope: nil
        )
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(report.failures[0].isPermissionDenied)
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertTrue(found.attachment.isPlaceholder)
        XCTAssertNotNil(found.attachment.image, "placeholder must never be blank")
        XCTAssertEqual(found.attachment.source, "assets/gone.png", "source must survive for save")
        XCTAssertEqual(found.attachment.naturalSize, ImageAttachmentController.placeholderSize)
        // Layout reports the placeholder bounds.
        let bounds = found.attachment.attachmentBounds(
            for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 600, height: 14),
            glyphPosition: .zero, characterIndex: 0
        )
        XCTAssertEqual(bounds.size, ImageAttachmentController.placeholderSize)
        // Serialization keeps the original reference.
        XCTAssertEqual(MarkdownSerializer.serialize(storage), "![gone](assets/gone.png)\n")
    }

    func testPercentEncodedSourceFallsBackToDecodedFile() throws {
        // The file on disk has a literal space; the source is %20-encoded.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try makeImageData(width: 8, height: 6)
            .write(to: assets.appendingPathComponent("pasted image.png"))
        let storage = makeStorage("![p](assets/pasted%20image.png)")
        let report = ImageAttachmentController.loadImages(
            in: storage, documentURL: dir.appendingPathComponent("doc.md"), scope: nil
        )
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.loadedAny)
    }

    func testRemoteURLBecomesPlaceholderWithoutFetching() throws {
        let storage = makeStorage("![r](https://example.com/x.png)")
        let report = ImageAttachmentController.loadImages(in: storage, documentURL: nil, scope: nil)
        // No failure recorded: a remote source is never even attempted.
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.loadedAny)
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertTrue(found.attachment.isPlaceholder)
        XCTAssertEqual(found.attachment.source, "https://example.com/x.png")
    }

    func testRelativeSourceWithoutDocumentBecomesPlaceholder() throws {
        let storage = makeStorage("![p](assets/pic.png)")
        let report = ImageAttachmentController.loadImages(in: storage, documentURL: nil, scope: nil)
        XCTAssertTrue(report.failures.isEmpty)
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertTrue(found.attachment.isPlaceholder)
    }

    func testRetryPlaceholdersLoadsAfterDocumentGetsLocation() throws {
        let (dir, storage) = try makeDocumentWithAsset()
        defer { try? FileManager.default.removeItem(at: dir) }
        // First pass: unsaved document → placeholder.
        _ = ImageAttachmentController.loadImages(in: storage, documentURL: nil, scope: nil)
        var found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertTrue(found.attachment.isPlaceholder)
        // Second pass after the "save": placeholders re-resolve.
        let report = ImageAttachmentController.loadImages(
            in: storage, documentURL: dir.appendingPathComponent("doc.md"),
            scope: nil, retryPlaceholders: true
        )
        XCTAssertTrue(report.loadedAny)
        found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertFalse(found.attachment.isPlaceholder)
        XCTAssertEqual(found.attachment.naturalSize?.width ?? 0, 8, accuracy: 0.1)
    }

    func testLoadedImagesAreNotReloaded() throws {
        let (dir, storage) = try makeDocumentWithAsset()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docURL = dir.appendingPathComponent("doc.md")
        _ = ImageAttachmentController.loadImages(in: storage, documentURL: docURL, scope: nil)
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        let loadedImage = found.attachment.image
        let report = ImageAttachmentController.loadImages(
            in: storage, documentURL: docURL, scope: nil, retryPlaceholders: true
        )
        XCTAssertFalse(report.loadedAny, "already-loaded images must be left alone")
        XCTAssertTrue(found.attachment.image === loadedImage)
    }

    // MARK: - Lookup

    func testImageAttachmentLookup() throws {
        let storage = makeStorage("text ![a](b.png) end")
        XCTAssertNil(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 5, in: storage))
        XCTAssertEqual(found.attachment.altText, "a")
        XCTAssertEqual(found.range.length, 1)
        XCTAssertNil(ImageAttachmentController.imageAttachment(at: storage.length, in: storage))
    }

    // MARK: - Insertion

    func testInsertReplacesSelectionAndSerializes() {
        let storage = makeStorage("abcdef")
        let attachment = MDImageAttachment(source: "assets/a.png", altText: "a", title: nil)
        let cursor = ImageAttachmentController.insert(
            attachment: attachment, storage: storage, selection: NSRange(location: 2, length: 2)
        )
        XCTAssertEqual(cursor, 3)
        XCTAssertEqual(MarkdownSerializer.serialize(storage), "ab![a](assets/a.png)ef\n")
    }

    // MARK: - Alt text editing

    func testApplyAltEditRoundTripsThroughSerializer() throws {
        let storage = makeStorage("![old](assets/pic.png)")
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        ImageAttachmentController.applyAltEdit(altText: "new alt", title: "  the title  ", to: found.attachment)
        XCTAssertEqual(found.attachment.altText, "new alt")
        XCTAssertEqual(found.attachment.title, "the title", "title is trimmed")
        let markdown = MarkdownSerializer.serialize(storage)
        XCTAssertEqual(markdown, "![new alt](assets/pic.png \"the title\")\n")
        // And back: parse keeps all three fields.
        let reparsed = makeStorage(markdown)
        let re = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: reparsed))
        XCTAssertEqual(re.attachment.altText, "new alt")
        XCTAssertEqual(re.attachment.title, "the title")
        XCTAssertEqual(re.attachment.source, "assets/pic.png")
    }

    func testApplyAltEditEmptyTitleClears() throws {
        let storage = makeStorage("![a](assets/pic.png \"old title\")")
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: storage))
        XCTAssertEqual(found.attachment.title, "old title")
        ImageAttachmentController.applyAltEdit(altText: "a", title: "   ", to: found.attachment)
        XCTAssertNil(found.attachment.title)
        XCTAssertEqual(MarkdownSerializer.serialize(storage), "![a](assets/pic.png)\n")
    }
}
