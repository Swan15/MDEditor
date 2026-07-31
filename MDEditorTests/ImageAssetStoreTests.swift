import XCTest
@testable import MDEditor

/// The on-disk asset store: relative paths, dedupe, format handling and the
/// unsaved-document abort path.
final class ImageAssetStoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorAssetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImageData(width: Int, height: Int, type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: type, properties: [:])!
    }

    private func removeOnExit(_ dir: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Relative paths

    func testRelativePathIsDocumentRelativePOSIX() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let documentURL = dir.appendingPathComponent("doc.md")
        let asset = dir.appendingPathComponent("assets").appendingPathComponent("foo.png")
        XCTAssertEqual(
            ImageAssetStore.relativePath(forAsset: asset, documentURL: documentURL),
            "assets/foo.png"
        )
    }

    // MARK: - Verbatim formats

    func testStorePNGFileCopiesBytesVerbatim() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let png = makeImageData(width: 8, height: 6, type: .png)
        let source = dir.appendingPathComponent("original.png")
        try png.write(to: source)
        let stored = try ImageAssetStore.storeImage(from: source, documentURL: dir.appendingPathComponent("doc.md"))
        XCTAssertEqual(stored.relativePath, "assets/original.png")
        XCTAssertEqual(stored.fileURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: stored.fileURL), png, "png bytes must not be re-encoded")
    }

    func testStoreJPEGKeepsExtension() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let jpeg = makeImageData(width: 8, height: 6, type: .jpeg)
        let source = dir.appendingPathComponent("photo.JPEG")
        try jpeg.write(to: source)
        let stored = try ImageAssetStore.storeImage(from: source, documentURL: dir.appendingPathComponent("doc.md"))
        XCTAssertEqual(stored.relativePath, "assets/photo.jpeg")
        XCTAssertEqual(try Data(contentsOf: stored.fileURL), jpeg)
    }

    // MARK: - PNG conversion

    func testStoreTIFFConvertsToPNG() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let tiff = makeImageData(width: 8, height: 6, type: .tiff)
        let source = dir.appendingPathComponent("scan.tiff")
        try tiff.write(to: source)
        let stored = try ImageAssetStore.storeImage(from: source, documentURL: dir.appendingPathComponent("doc.md"))
        XCTAssertEqual(stored.relativePath, "assets/scan.png")
        let data = try Data(contentsOf: stored.fileURL)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "converted data must be PNG")
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 8)
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsHigh, 6)
    }

    func testStorePastedPNGDataIsWrittenVerbatim() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let png = makeImageData(width: 4, height: 4, type: .png)
        let stored = try ImageAssetStore.storeImage(
            data: png, suggestedName: "pasted-image", documentURL: dir.appendingPathComponent("doc.md")
        )
        XCTAssertEqual(stored.relativePath, "assets/pasted-image.png")
        XCTAssertEqual(try Data(contentsOf: stored.fileURL), png)
    }

    // MARK: - Dedupe

    func testDedupeNaming() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data().write(to: assets.appendingPathComponent("foo.png"))
        try Data().write(to: assets.appendingPathComponent("foo-2.png"))
        let deduped = ImageAssetStore.dedupedURL(in: assets, baseName: "foo", ext: "png")
        XCTAssertEqual(deduped.lastPathComponent, "foo-3.png")
    }

    func testStoreDedupesCollidingNames() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let png = makeImageData(width: 4, height: 4, type: .png)
        let first = try ImageAssetStore.storeImage(
            data: png, suggestedName: "shot", documentURL: dir.appendingPathComponent("doc.md")
        )
        let second = try ImageAssetStore.storeImage(
            data: png, suggestedName: "shot", documentURL: dir.appendingPathComponent("doc.md")
        )
        XCTAssertEqual(first.relativePath, "assets/shot.png")
        XCTAssertEqual(second.relativePath, "assets/shot-2.png")
    }

    // MARK: - Spaces in filenames

    func testSpacesInFilenameRoundTripThroughMarkdown() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let png = makeImageData(width: 4, height: 4, type: .png)
        let source = dir.appendingPathComponent("my pic.png")
        try png.write(to: source)
        let stored = try ImageAssetStore.storeImage(from: source, documentURL: dir.appendingPathComponent("doc.md"))
        XCTAssertEqual(stored.relativePath, "assets/my pic.png", "literal spaces, not %20")
        // Serializer wraps the spaced destination in <…> …
        let attachment = MDImageAttachment(source: stored.relativePath, altText: "my pic", title: nil)
        let storage = NSTextStorage()
        storage.append(NSAttributedString(attachment: attachment))
        let markdown = MarkdownSerializer.serialize(storage)
        XCTAssertEqual(markdown, "![my pic](<assets/my pic.png>)\n")
        // … and the parser reads it back byte-for-byte.
        let reparsed = NSTextStorage()
        reparsed.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        let found = try XCTUnwrap(ImageAttachmentController.imageAttachment(at: 0, in: reparsed))
        XCTAssertEqual(found.attachment.source, "assets/my pic.png")
    }

    // MARK: - Unsaved document (abort seam)

    func testUnsavedDocumentThrowsFromData() throws {
        let png = makeImageData(width: 4, height: 4, type: .png)
        XCTAssertThrowsError(
            try ImageAssetStore.storeImage(data: png, suggestedName: "x", documentURL: nil)
        ) { error in
            XCTAssertEqual(error as? ImageAssetStore.StoreError, .unsavedDocument)
        }
    }

    func testUnsavedDocumentThrowsFromFile() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let source = dir.appendingPathComponent("x.png")
        try makeImageData(width: 4, height: 4, type: .png).write(to: source)
        XCTAssertThrowsError(
            try ImageAssetStore.storeImage(from: source, documentURL: nil)
        ) { error in
            XCTAssertEqual(error as? ImageAssetStore.StoreError, .unsavedDocument)
        }
    }
}
