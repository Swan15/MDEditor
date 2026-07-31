import XCTest
@testable import MDEditor

/// The workspace file tree: filtering, sorting, lazy children, name dedupe
/// and the on-disk context-menu operations.
final class FileTreeModelTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorFileTreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeOnExit(_ dir: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func makeFile(_ name: String, in dir: URL, contents: String = "") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func makeFolder(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    // MARK: - Filtering

    func testScanShowsFoldersAndMarkdownOnly() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile("notes.md", in: dir)
        try makeFile("long.markdown", in: dir)
        try makeFile("UPPER.MD", in: dir)
        try makeFile("draft.txt", in: dir)
        try makeFile("image.png", in: dir)
        try makeFolder("sub", in: dir)
        try makeFolder("assets", in: dir)

        let names = FileTreeModel.scanChildren(of: dir).map(\.name)
        XCTAssertTrue(names.contains("notes.md"))
        XCTAssertTrue(names.contains("long.markdown"))
        XCTAssertTrue(names.contains("UPPER.MD"), "extension matching is case-insensitive")
        XCTAssertTrue(names.contains("sub"))
        XCTAssertTrue(names.contains("assets"), "folders are shown generally, asset dirs included")
        XCTAssertFalse(names.contains("draft.txt"))
        XCTAssertFalse(names.contains("image.png"))
    }

    func testScanHidesDotfilesAndDotfolders() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile(".hidden.md", in: dir)
        try makeFolder(".git", in: dir)
        try makeFile("visible.md", in: dir)

        let names = FileTreeModel.scanChildren(of: dir).map(\.name)
        XCTAssertEqual(names, ["visible.md"])
    }

    func testScanMissingDirectoryIsEmpty() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        XCTAssertTrue(FileTreeModel.scanChildren(of: gone).isEmpty)
    }

    // MARK: - Sorting

    func testScanSortsFoldersFirstThenFilesCaseInsensitive() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFolder("Zeta", in: dir)
        try makeFolder("alpha", in: dir)
        try makeFile("B.md", in: dir)
        try makeFile("a.md", in: dir)

        let nodes = FileTreeModel.scanChildren(of: dir)
        XCTAssertEqual(nodes.map(\.name), ["alpha", "Zeta", "a.md", "B.md"])
        XCTAssertTrue(nodes.prefix(2).allSatisfy(\.isFolder))
        XCTAssertTrue(nodes.suffix(2).allSatisfy { !$0.isFolder })
    }

    // MARK: - Lazy children

    func testScannedFolderChildrenAreNilUntilExpanded() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile("nested.md", in: try makeFolder("sub", in: dir))
        let folder = try XCTUnwrap(FileTreeModel.scanChildren(of: dir).first)
        XCTAssertTrue(folder.isFolder)
        XCTAssertNil(folder.children, "children load lazily, not during the scan")
    }

    // MARK: - Dedupe

    func testDedupedURLSequence() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile("untitled.md", in: dir)
        try makeFile("untitled-2.md", in: dir)
        let deduped = FileTreeOperations.dedupedURL(
            in: dir, baseName: "untitled", pathExtension: "md", separator: "-"
        )
        XCTAssertEqual(deduped.lastPathComponent, "untitled-3.md")
    }

    func testDedupedFolderUsesFinderStyleSpace() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFolder("untitled folder", in: dir)
        let deduped = FileTreeOperations.dedupedURL(
            in: dir, baseName: "untitled folder", pathExtension: nil, separator: " "
        )
        XCTAssertEqual(deduped.lastPathComponent, "untitled folder 2")
    }

    // MARK: - Create

    func testCreateMarkdownFileDedupesOnDisk() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let first = try FileTreeOperations.createMarkdownFile(in: dir)
        let second = try FileTreeOperations.createMarkdownFile(in: dir)
        XCTAssertEqual(first.lastPathComponent, "untitled.md")
        XCTAssertEqual(second.lastPathComponent, "untitled-2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "")
    }

    func testCreateFolderDedupesOnDisk() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let first = try FileTreeOperations.createFolder(in: dir)
        let second = try FileTreeOperations.createFolder(in: dir)
        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Rename

    func testRenameMovesOnDisk() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let original = try makeFile("old.md", in: dir, contents: "# Hi")
        let renamed = try FileTreeOperations.rename(at: original, to: "new.md")
        XCTAssertEqual(renamed.lastPathComponent, "new.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "# Hi", "content survives the move")
    }

    func testRenameCollisionThrowsAndKeepsBothFiles() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let first = try makeFile("a.md", in: dir, contents: "a")
        let second = try makeFile("b.md", in: dir, contents: "b")
        XCTAssertThrowsError(try FileTreeOperations.rename(at: first, to: "b.md")) { error in
            XCTAssertEqual(error as? FileTreeOperations.OperationError, .nameAlreadyExists("b.md"))
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "b")
    }

    // MARK: - Trash

    func testMoveToTrashRemovesFromOriginalLocation() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = try makeFile("doomed.md", in: dir)
        try FileTreeOperations.moveToTrash(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
