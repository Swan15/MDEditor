import XCTest
@testable import MDEditor

/// The workspace model: lazy tree loading, in-place rescans (identity and
/// expansion survive), reveal and close. The watcher is disabled so every
/// rescan is driven synchronously.
@MainActor
final class WorkspaceModelTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorWorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeOnExit(_ dir: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private func makeFolder(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeModel() -> WorkspaceModel {
        WorkspaceModel(watchingEnabled: false)
    }

    // MARK: - Open / close

    func testOpenWorkspaceLoadsTopLevelOnly() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile("root.md", in: dir)
        let sub = try makeFolder("sub", in: dir)
        try makeFile("nested.md", in: sub)

        let model = makeModel()
        model.openWorkspace(at: dir)

        XCTAssertEqual(model.root, dir.standardizedFileURL)
        XCTAssertEqual(model.nodes.map(\.name), ["sub", "root.md"])
        let subNode = try XCTUnwrap(model.nodes.first)
        XCTAssertNil(subNode.children, "top-level scan stays shallow; folders load on expand")
    }

    func testCloseWorkspaceClearsState() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try makeFile("a.md", in: dir)
        let model = makeModel()
        model.openWorkspace(at: dir)
        model.closeWorkspace()

        XCTAssertNil(model.root)
        XCTAssertTrue(model.nodes.isEmpty)
        XCTAssertTrue(model.expandedURLs.isEmpty)
    }

    // MARK: - Expansion / lazy loading

    func testExpandLoadsChildrenLazily() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let sub = try makeFolder("sub", in: dir)
        try makeFile("nested.md", in: sub)

        let model = makeModel()
        model.openWorkspace(at: dir)
        let subNode = try XCTUnwrap(model.nodes.first)

        model.setExpanded(subNode, true)
        XCTAssertEqual(subNode.children?.map(\.name), ["nested.md"])
        XCTAssertTrue(model.expandedURLs.contains(subNode.url))

        model.setExpanded(subNode, false)
        XCTAssertFalse(model.expandedURLs.contains(subNode.url))
        XCTAssertNotNil(subNode.children, "children stay loaded after collapse")
    }

    /// Bug: only the disclosure chevron toggled a folder; clicking the row
    /// itself did nothing. The row's tap handler flips expansion through
    /// this exact seam — read `expandedURLs`, write `setExpanded` — the
    /// same one the disclosure binding uses.
    func testFolderRowTapTogglesExpansion() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let sub = try makeFolder("sub", in: dir)
        try makeFile("nested.md", in: sub)

        let model = makeModel()
        model.openWorkspace(at: dir)
        let subNode = try XCTUnwrap(model.nodes.first)

        // Exactly what SidebarView's folder-row button does on a tap.
        model.setExpanded(subNode, !model.expandedURLs.contains(subNode.url))
        XCTAssertTrue(model.expandedURLs.contains(subNode.url), "tap on a collapsed folder expands it")
        XCTAssertEqual(subNode.children?.map(\.name), ["nested.md"], "expanding loads the children")

        model.setExpanded(subNode, !model.expandedURLs.contains(subNode.url))
        XCTAssertFalse(model.expandedURLs.contains(subNode.url), "a second tap collapses it again")
    }

    // MARK: - Rescan

    func testRescanPicksUpNewFile() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let model = makeModel()
        model.openWorkspace(at: dir)
        XCTAssertTrue(model.nodes.isEmpty)

        try makeFile("added.md", in: dir)
        model.rescan(directory: dir)
        XCTAssertEqual(model.nodes.map(\.name), ["added.md"])
    }

    func testRescanDropsDeletedFile() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = try makeFile("gone.md", in: dir)
        let model = makeModel()
        model.openWorkspace(at: dir)
        XCTAssertEqual(model.nodes.count, 1)

        try FileManager.default.removeItem(at: file)
        model.rescan(directory: dir)
        XCTAssertTrue(model.nodes.isEmpty)
    }

    func testRescanKeepsNodeIdentityAndExpansion() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let sub = try makeFolder("sub", in: dir)
        try makeFile("nested.md", in: sub)

        let model = makeModel()
        model.openWorkspace(at: dir)
        let subNode = try XCTUnwrap(model.nodes.first)
        model.setExpanded(subNode, true)

        // A new sibling appears; the folder node and its children must survive.
        try makeFile("new.md", in: dir)
        model.rescan(directory: dir)

        XCTAssertEqual(model.nodes.map(\.name), ["sub", "new.md"])
        XCTAssertTrue(model.nodes.first === subNode, "reconcile keeps node identity for survivors")
        XCTAssertEqual(subNode.children?.map(\.name), ["nested.md"])
        XCTAssertTrue(model.expandedURLs.contains(subNode.url))
    }

    func testRescanRefreshesExpandedFolder() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let sub = try makeFolder("sub", in: dir)
        let model = makeModel()
        model.openWorkspace(at: dir)
        let subNode = try XCTUnwrap(model.nodes.first)
        model.setExpanded(subNode, true)
        XCTAssertEqual(subNode.children?.count, 0)

        try makeFile("later.md", in: sub)
        model.rescan(directory: sub)
        XCTAssertEqual(subNode.children?.map(\.name), ["later.md"])
    }

    // MARK: - Reveal

    func testRevealExpandsAncestors() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let a = try makeFolder("a", in: dir)
        let b = try makeFolder("b", in: a)
        let file = try makeFile("c.md", in: b)

        let model = makeModel()
        model.openWorkspace(at: dir)
        model.reveal(file)

        XCTAssertTrue(model.expandedURLs.contains(a.standardizedFileURL))
        XCTAssertTrue(model.expandedURLs.contains(b.standardizedFileURL))
        XCTAssertEqual(model.lastRevealedURL, file.standardizedFileURL)
        let aNode = try XCTUnwrap(model.nodes.first)
        XCTAssertEqual(aNode.children?.map(\.name), ["b"])
        XCTAssertEqual(aNode.children?.first?.children?.map(\.name), ["c.md"])
    }

    func testRevealOutsideWorkspaceIsNoop() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let model = makeModel()
        model.openWorkspace(at: dir)
        model.reveal(URL(fileURLWithPath: "/etc/hosts"))

        XCTAssertTrue(model.expandedURLs.isEmpty)
        XCTAssertNil(model.lastRevealedURL)
    }
}
