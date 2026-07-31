import XCTest
@testable import MDEditor

/// Security-scoped bookmark persistence: round-trips, stale/corrupt data,
/// and the AppState-level session restore (workspace + document).
final class SessionRestoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeOnExit(_ dir: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorRestoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// Bookmarks may resolve to symlink-expanded paths; compare resolved forms.
    private func assertSameLocation(_ lhs: URL?, _ rhs: URL?, _ message: String = "") {
        XCTAssertEqual(
            lhs?.resolvingSymlinksInPath().path,
            rhs?.resolvingSymlinksInPath().path,
            message
        )
    }

    // MARK: - Bookmark round-trip

    func testBookmarkRoundTrip() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try "# Hi".write(to: file, atomically: true, encoding: .utf8)

        let data = try XCTUnwrap(SessionRestore.bookmarkData(for: file))
        let resolved = try XCTUnwrap(SessionRestore.resolve(data))
        assertSameLocation(resolved, file)
    }

    func testResolveGarbageDataReturnsNil() {
        XCTAssertNil(SessionRestore.resolve(Data([0x00, 0x01, 0x02, 0x03])))
    }

    // MARK: - Persist / restoreURLs

    func testPersistAndRestoreRoundTrip() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try Data().write(to: file)
        let defaults = try makeDefaults()

        SessionRestore.persist(fileURL: file, workspaceRoot: dir, defaults: defaults)
        let restored = SessionRestore.restoreURLs(defaults: defaults)
        assertSameLocation(restored.file, file)
        assertSameLocation(restored.workspace, dir)
    }

    func testPersistNilClearsEntries() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let defaults = try makeDefaults()

        SessionRestore.persist(fileURL: dir, workspaceRoot: dir, defaults: defaults)
        SessionRestore.persist(fileURL: nil, workspaceRoot: nil, defaults: defaults)
        let restored = SessionRestore.restoreURLs(defaults: defaults)
        XCTAssertNil(restored.file)
        XCTAssertNil(restored.workspace)
    }

    // MARK: - Multi-window persist / restore

    func testMultiWindowPersistRestoresAllInOrder() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let fileA = dir.appendingPathComponent("a.md")
        let fileB = dir.appendingPathComponent("b.md")
        try Data().write(to: fileA)
        try Data().write(to: fileB)
        let defaults = try makeDefaults()

        SessionRestore.persist(windows: [
            WindowSession(fileURL: fileA),
            WindowSession(fileURL: fileB, workspaceRoot: dir),
        ], defaults: defaults)
        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)

        XCTAssertEqual(entries.count, 2)
        assertSameLocation(entries[0].fileURL, fileA)
        XCTAssertNil(entries[0].workspaceRoot)
        assertSameLocation(entries[1].fileURL, fileB)
        assertSameLocation(entries[1].workspaceRoot, dir)
    }

    /// Entries whose bookmarks can't be created (dead locations) drop out.
    func testRestoreDropsUnresolvableEntries() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try Data().write(to: file)
        let defaults = try makeDefaults()

        let dead = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/gone.md")
        SessionRestore.persist(windows: [
            WindowSession(fileURL: dead),
            WindowSession(fileURL: file),
        ], defaults: defaults)
        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)

        XCTAssertEqual(entries.count, 1)
        assertSameLocation(entries[0].fileURL, file)
    }

    func testRestoreCapsWindowCount() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        var windows: [WindowSession] = []
        for index in 0..<(SessionRestore.maxRestoredWindows + 2) {
            let file = dir.appendingPathComponent("\(index).md")
            try Data().write(to: file)
            windows.append(WindowSession(fileURL: file))
        }
        let defaults = try makeDefaults()

        SessionRestore.persist(windows: windows, defaults: defaults)
        XCTAssertEqual(SessionRestore.restoreWindowEntries(defaults: defaults).count, SessionRestore.maxRestoredWindows)
    }

    /// A pre-multi-window session (legacy keys) reads back as one entry and
    /// clears its legacy keys.
    func testLegacySessionMigrates() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try Data().write(to: file)
        let defaults = try makeDefaults()

        SessionRestore.persist(fileURL: file, workspaceRoot: dir, defaults: defaults)
        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)

        XCTAssertEqual(entries.count, 1)
        assertSameLocation(entries[0].fileURL, file)
        assertSameLocation(entries[0].workspaceRoot, dir)
        let legacy = SessionRestore.restoreURLs(defaults: defaults)
        XCTAssertNil(legacy.file, "legacy keys are cleared after migration")
        XCTAssertNil(legacy.workspace)
    }

    // MARK: - Hot-exit backup references

    /// An entry carrying only an untitled backup ID (hot-exited window)
    /// round-trips and counts as restorable content.
    func testBackupIDOnlyEntryRoundTrips() throws {
        let defaults = try makeDefaults()
        let backupID = UUID()

        SessionRestore.persist(windows: [WindowSession(untitledBackupID: backupID)], defaults: defaults)
        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].untitledBackupID, backupID)
        XCTAssertNil(entries[0].fileURL)
        XCTAssertTrue(entries[0].hasContent)
    }

    /// Sessions written before hot exit existed (no backup key in the
    /// stored JSON) still decode — the ID simply reads back as nil.
    func testPreHotExitSessionFormatDecodes() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try Data().write(to: file)
        let defaults = try makeDefaults()
        let bookmark = try XCTUnwrap(SessionRestore.bookmarkData(for: file))
        // The old StoredWindow shape: file/workspace bookmarks only (Data
        // goes into JSON as base64, JSONEncoder's default).
        let oldFormat: [[String: Any]] = [["file": bookmark.base64EncodedString()]]
        let data = try JSONSerialization.data(withJSONObject: oldFormat)
        defaults.set(data, forKey: "restore.windows")

        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)

        XCTAssertEqual(entries.count, 1)
        assertSameLocation(entries[0].fileURL, file)
        XCTAssertNil(entries[0].untitledBackupID, "the missing key decodes as nil")
    }

    // MARK: - AppState restore

    @MainActor
    func testAppStateRestoresOpenDocument() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try "# Restored".write(to: file, atomically: true, encoding: .utf8)
        let defaults = try makeDefaults()

        let appState = AppState(userDefaults: defaults, restore: WindowSession(fileURL: file))
        appState.restoreSessionIfNeeded()

        XCTAssertTrue(appState.hasDocument)
        XCTAssertEqual(appState.document.fileURL, file.standardizedFileURL)
        XCTAssertEqual(appState.document.pendingMarkdown, "# Restored")
        XCTAssertFalse(appState.document.isDirty)
        XCTAssertNil(appState.workspaceRoot)
    }

    @MainActor
    func testAppStateRestoresWorkspace() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        try Data().write(to: dir.appendingPathComponent("note.md"))
        let defaults = try makeDefaults()

        let appState = AppState(userDefaults: defaults, restore: WindowSession(workspaceRoot: dir))
        appState.restoreSessionIfNeeded()

        XCTAssertEqual(
            appState.workspaceRoot?.resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(appState.workspace.nodes.map(\.name), ["note.md"])
    }

    @MainActor
    func testAppStateDropsStaleRestoreSilently() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("gone.md")
        try Data().write(to: file)
        let defaults = try makeDefaults()

        // The file vanishes between sessions; the entry still points at it.
        try FileManager.default.removeItem(at: file)

        let appState = AppState(userDefaults: defaults, restore: WindowSession(fileURL: file))
        appState.restoreSessionIfNeeded()

        XCTAssertFalse(appState.hasDocument, "a failed restore leaves the window in the empty state")
        XCTAssertNil(appState.document.fileURL)
        XCTAssertTrue(
            SessionRestore.restoreWindowEntries(defaults: defaults).isEmpty,
            "the failed restore re-persisted an empty entry, which restores as nothing"
        )
    }

    @MainActor
    func testRestoreRunsOnlyOnce() throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let file = dir.appendingPathComponent("doc.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let defaults = try makeDefaults()

        let appState = AppState(userDefaults: defaults, restore: WindowSession(fileURL: file))
        appState.restoreSessionIfNeeded()
        XCTAssertEqual(appState.document.pendingMarkdown, "one")

        // A second call must not reload (e.g. after the user opened something else).
        appState.document.loadMarkdown("two")
        appState.restoreSessionIfNeeded()
        XCTAssertEqual(appState.document.pendingMarkdown, "two")
    }
}
