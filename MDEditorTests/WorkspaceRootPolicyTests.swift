import XCTest
@testable import MDEditor

/// Bug: opening a file from outside the sidebar (⌘O, recents, welcome,
/// session restore) left the sidebar empty / showing an unrelated folder.
/// The fix adopts the file's parent folder as the workspace root whenever
/// the file is outside the current root (`WorkspaceRootPolicy`, pure), and
/// `openDocument(at:)` applies it — the sidebar then shows the opened file.
final class WorkspaceRootPolicyTests: XCTestCase {
    /// StyleEngine.fontSettings is global (set by AppState.init); save/restore.
    private var savedFontSettings: AppSettings?

    override func setUp() {
        super.setUp()
        savedFontSettings = StyleEngine.fontSettings
        StyleEngine.fontSettings = nil
    }

    override func tearDown() {
        StyleEngine.fontSettings = savedFontSettings
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorWorkspaceRootPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorWorkspaceRootPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.standardizedFileURL
    }

    // MARK: - Pure decision matrix

    /// No workspace open: the file's parent folder becomes the root.
    func testNilRootAdoptsParentFolder() {
        let file = URL(fileURLWithPath: "/a/b/notes.md")
        XCTAssertEqual(
            WorkspaceRootPolicy.rootForOpenedFile(currentRoot: nil, openedFileURL: file),
            URL(fileURLWithPath: "/a/b")
        )
    }

    /// Inside the current root (top level or nested): keep the workspace.
    func testFileInsideCurrentRootKeepsWorkspace() {
        let root = URL(fileURLWithPath: "/a/b")
        XCTAssertNil(WorkspaceRootPolicy.rootForOpenedFile(
            currentRoot: root, openedFileURL: URL(fileURLWithPath: "/a/b/notes.md")
        ))
        XCTAssertNil(WorkspaceRootPolicy.rootForOpenedFile(
            currentRoot: root, openedFileURL: URL(fileURLWithPath: "/a/b/sub/deep/notes.md")
        ))
    }

    /// Outside the current root: adopt the file's parent, replacing the
    /// current workspace (the sidebar must follow the opened file).
    func testFileOutsideCurrentRootAdoptsItsParent() {
        let root = URL(fileURLWithPath: "/a/b")
        XCTAssertEqual(
            WorkspaceRootPolicy.rootForOpenedFile(
                currentRoot: root, openedFileURL: URL(fileURLWithPath: "/x/y/notes.md")
            ),
            URL(fileURLWithPath: "/x/y")
        )
        // A sibling folder of the root is outside it (prefix "/a/b" must
        // not match "/a/b2").
        XCTAssertEqual(
            WorkspaceRootPolicy.rootForOpenedFile(
                currentRoot: root, openedFileURL: URL(fileURLWithPath: "/a/b2/notes.md")
            ),
            URL(fileURLWithPath: "/a/b2")
        )
    }

    // MARK: - openDocument(at:) integration (readable folders → no prompt)

    /// ⌘O with no workspace: the sidebar adopts the file's folder and
    /// reveals the file.
    @MainActor
    func testOpenDocumentWithoutWorkspaceAdoptsParentFolder() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("notes.md")
        try "# Notes".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(userDefaults: try makeDefaults())

        state.openDocument(at: file)

        XCTAssertEqual(state.workspaceRoot, dir, "the parent folder becomes the workspace root")
        XCTAssertEqual(state.workspace.nodes.map(\.name), ["notes.md"])
        XCTAssertEqual(state.workspace.lastRevealedURL, file.standardizedFileURL)
    }

    /// A file inside the current workspace (e.g. a sidebar click) leaves
    /// the root alone and just reveals.
    @MainActor
    func testOpenDocumentInsideWorkspaceKeepsRoot() throws {
        let dir = try makeTempDir()
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let file = sub.appendingPathComponent("nested.md")
        try "# Nested".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(userDefaults: try makeDefaults())
        state.openWorkspace(at: dir)

        state.openDocument(at: file)

        XCTAssertEqual(state.workspaceRoot, dir, "the workspace stays as-is")
        XCTAssertEqual(state.workspace.lastRevealedURL, file.standardizedFileURL)
    }

    /// A file outside the current workspace replaces the root with the
    /// file's folder.
    @MainActor
    func testOpenDocumentOutsideWorkspaceReplacesRoot() throws {
        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        let file = dirA.appendingPathComponent("elsewhere.md")
        try "# Elsewhere".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(userDefaults: try makeDefaults())
        state.openWorkspace(at: dirB)

        state.openDocument(at: file)

        XCTAssertEqual(state.workspaceRoot, dirA, "the workspace follows the opened file")
        XCTAssertEqual(state.workspace.lastRevealedURL, file.standardizedFileURL)
    }
}
