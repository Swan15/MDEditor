import AppKit
import XCTest
@testable import MDEditor

/// End-to-end document lifecycle at the AppState/WindowRegistry level:
/// ⌘W closes to the empty state (never a phantom untitled), window close
/// hot-exits dirty untitled documents without an alert, relaunch restores
/// them, and backups are retired on save / clean close.
@MainActor
final class DocumentLifecycleTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeStore(in dir: URL) -> HotExitStore {
        HotExitStore(directory: dir.appendingPathComponent("UntitledBackups", isDirectory: true))
    }

    private func makeState(defaults: UserDefaults, store: HotExitStore, restore: WindowSession? = nil) -> AppState {
        AppState(userDefaults: defaults, restore: restore, hotExitStore: store)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// An untitled document holding `content` (no editor mounted: the model's
    /// pending Markdown stands in for the text storage).
    private func makeUntitledDocument(in state: AppState, content: String) {
        state.hasDocument = true
        state.document.loadMarkdown(content)
    }

    // MARK: - Empty state & document-state derivation

    func testNewWindowStartsInEmptyState() throws {
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: try makeTempDir()))
        XCTAssertFalse(state.hasDocument)
        XCTAssertEqual(state.documentState, .none)
        XCTAssertFalse(state.isDirtyForPolicy)
    }

    func testDocumentStateDerivesFromHasDocumentAndFileURL() throws {
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: try makeTempDir()))
        XCTAssertEqual(state.documentState, .none)
        makeUntitledDocument(in: state, content: "")
        XCTAssertEqual(state.documentState, .untitled)
        state.document.fileURL = URL(fileURLWithPath: "/tmp/x.md")
        XCTAssertEqual(state.documentState, .file)
    }

    /// An untitled document counts as dirty only while it holds content
    /// (VSCode: empty untitled = clean, no prompt, no backup).
    func testUntitledDirtyOnlyWithContent() throws {
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: try makeTempDir()))
        makeUntitledDocument(in: state, content: "")
        XCTAssertFalse(state.isDirtyForPolicy, "empty untitled is clean")
        state.document.loadMarkdown("# Draft")
        XCTAssertTrue(state.isDirtyForPolicy)
        state.document.loadMarkdown("  \n  ")
        XCTAssertFalse(state.isDirtyForPolicy, "whitespace-only untitled is clean")
    }

    // MARK: - New document

    func testNewDocumentFromEmptyStatePresentsUntitled() throws {
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: try makeTempDir()))
        state.requestNewDocument()
        XCTAssertTrue(state.hasDocument)
        XCTAssertEqual(state.documentState, .untitled)
        XCTAssertEqual(state.document.pendingMarkdown, "")
        XCTAssertFalse(state.document.isDirty)
    }

    // MARK: - Close Document (⌘W)

    /// The main jank being removed: ⌘W on a clean file goes to the empty
    /// state — it must NOT reset to a phantom untitled document.
    func testCloseDocumentOnCleanFileGoesToEmptyState() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let state = makeState(defaults: defaults, store: makeStore(in: dir))
        let file = dir.appendingPathComponent("notes.md")
        try "# Notes".write(to: file, atomically: true, encoding: .utf8)
        state.openDocument(at: file)
        XCTAssertTrue(state.hasDocument)

        state.closeDocument()

        XCTAssertFalse(state.hasDocument, "the window now shows the welcome view")
        XCTAssertNil(state.document.fileURL)
        XCTAssertEqual(state.documentState, .none)
        XCTAssertTrue(
            SessionRestore.restoreWindowEntries(defaults: defaults).allSatisfy { $0.fileURL == nil },
            "the persisted session no longer references the closed file (the adopted workspace stays open)"
        )
    }

    /// ⌘W on a dirty file with autosave ON saves silently, then empties.
    func testCloseDocumentOnDirtyFileWithAutosaveSavesSilently() throws {
        let dir = try makeTempDir()
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: dir))
        let file = dir.appendingPathComponent("notes.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        state.openDocument(at: file)
        state.document.loadMarkdown("changed")
        state.document.isDirty = true

        state.closeDocument()

        XCTAssertFalse(state.hasDocument)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    /// ⌘W on a clean untitled document (incl. an emptied restored backup)
    /// closes immediately and deletes any leftover backup.
    func testCloseDocumentOnCleanUntitledDeletesBackup() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        makeUntitledDocument(in: state, content: "# Draft")
        state.stashUntitledBackup()
        let backupID = try XCTUnwrap(state.untitledBackupID)
        // The user deletes all content: the untitled document is clean now.
        state.document.loadMarkdown("")

        state.closeDocument()

        XCTAssertFalse(state.hasDocument)
        XCTAssertNil(state.untitledBackupID)
        XCTAssertNil(store.restore(id: backupID), "closing clean retires the backup")
    }

    // MARK: - Window close (red button): hot exit

    /// Dirty untitled + red button: the backup is written and the close
    /// proceeds with NO alert (windowShouldClose answers true synchronously).
    func testWindowCloseOnDirtyUntitledStashesWithoutAlert() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let state = makeState(defaults: defaults, store: store)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let window = makeWindow()
        registry.attach(window: window, appState: state)
        makeUntitledDocument(in: state, content: "# Draft\n\nunsaved thoughts")

        let shouldClose = registry.records[0].closeController.windowShouldClose(window)

        XCTAssertTrue(shouldClose, "hot exit never blocks the close with an alert")
        let backupID = try XCTUnwrap(state.untitledBackupID)
        XCTAssertEqual(store.restore(id: backupID), "# Draft\n\nunsaved thoughts")

        // The closed window's session entry survives (restore on relaunch).
        registry.unregister(window: window)
        let entries = SessionRestore.restoreWindowEntries(defaults: defaults)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].untitledBackupID, backupID)
        XCTAssertNil(entries[0].fileURL)
    }

    /// Re-stashing on a later close reuses the same backup ID.
    func testStashReusesExistingBackupID() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        makeUntitledDocument(in: state, content: "one")
        state.stashUntitledBackup()
        let first = try XCTUnwrap(state.untitledBackupID)
        state.document.loadMarkdown("two")
        state.stashUntitledBackup()
        XCTAssertEqual(state.untitledBackupID, first)
        XCTAssertEqual(store.restore(id: first), "two")
    }

    /// A clean window close discards a leftover backup (emptied untitled).
    func testWindowCloseOnCleanUntitledDiscardsBackup() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let window = makeWindow()
        registry.attach(window: window, appState: state)
        makeUntitledDocument(in: state, content: "# Draft")
        state.stashUntitledBackup()
        let backupID = try XCTUnwrap(state.untitledBackupID)
        state.document.loadMarkdown("") // emptied → clean

        let shouldClose = registry.records[0].closeController.windowShouldClose(window)

        XCTAssertTrue(shouldClose)
        XCTAssertNil(state.untitledBackupID)
        XCTAssertNil(store.restore(id: backupID))
    }

    // MARK: - Relaunch (session restore of untitled backups)

    func testRelaunchRestoresUntitledBackupWithContent() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let backupID = UUID()
        store.stash(content: "# Hot exit\n\nrestored draft", id: backupID)

        let state = makeState(
            defaults: defaults,
            store: store,
            restore: WindowSession(untitledBackupID: backupID)
        )
        state.restoreSessionIfNeeded()

        XCTAssertTrue(state.hasDocument)
        XCTAssertEqual(state.documentState, .untitled)
        XCTAssertEqual(state.document.pendingMarkdown, "# Hot exit\n\nrestored draft")
        XCTAssertTrue(state.document.isDirty, "restored untitled content exists nowhere on disk")
        XCTAssertEqual(state.untitledBackupID, backupID, "the window keeps referencing its backup")
    }

    func testRelaunchWithMissingBackupRestoresNothing() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)

        let state = makeState(
            defaults: defaults,
            store: store,
            restore: WindowSession(untitledBackupID: UUID())
        )
        state.restoreSessionIfNeeded()

        XCTAssertFalse(state.hasDocument, "a missing backup restores as the empty state, no crash")
        XCTAssertNil(state.untitledBackupID)
    }

    // MARK: - Save retires the backup

    /// Saving an untitled document to a real file deletes its hot-exit
    /// backup (the content now lives on disk).
    func testSavingUntitledToFileDeletesBackup() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        makeUntitledDocument(in: state, content: "# Draft")
        state.stashUntitledBackup()
        let backupID = try XCTUnwrap(state.untitledBackupID)

        let target = dir.appendingPathComponent("saved.md")
        state.write("# Draft", to: target)

        XCTAssertEqual(state.documentState, .file)
        XCTAssertEqual(state.document.fileURL, target.standardizedFileURL)
        XCTAssertNil(state.untitledBackupID)
        XCTAssertNil(store.restore(id: backupID), "the backup is retired once the content is on disk")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Draft")
    }

    // MARK: - Quit preparation

    func testPrepareForTerminationStashesDirtyUntitled() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        makeUntitledDocument(in: state, content: "# Draft")

        state.prepareForTermination()

        let backupID = try XCTUnwrap(state.untitledBackupID)
        XCTAssertEqual(store.restore(id: backupID), "# Draft")
        XCTAssertFalse(state.needsUnsavedFileChangesAlert, "untitled never blocks the quit")
    }

    func testPrepareForTerminationDropsBackupEmptiedSinceStash() throws {
        let dir = try makeTempDir()
        let store = makeStore(in: dir)
        let state = makeState(defaults: try makeDefaults(), store: store)
        makeUntitledDocument(in: state, content: "# Draft")
        state.stashUntitledBackup()
        let backupID = try XCTUnwrap(state.untitledBackupID)
        state.document.loadMarkdown("")

        state.prepareForTermination()

        XCTAssertNil(state.untitledBackupID)
        XCTAssertNil(store.restore(id: backupID))
    }

    func testPrepareForTerminationSavesDirtyFileWithAutosave() throws {
        let dir = try makeTempDir()
        let state = makeState(defaults: try makeDefaults(), store: makeStore(in: dir))
        let file = dir.appendingPathComponent("notes.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        state.openDocument(at: file)
        state.document.loadMarkdown("changed")
        state.document.isDirty = true

        state.prepareForTermination()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
        XCTAssertFalse(state.document.isDirty)
        XCTAssertFalse(state.needsUnsavedFileChangesAlert)
    }

    func testPrepareForTerminationLeavesDirtyFileWithoutAutosaveAlone() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.autosaveEnabled = false
        let state = AppState(
            userDefaults: defaults,
            settings: settings,
            hotExitStore: makeStore(in: dir)
        )
        let file = dir.appendingPathComponent("notes.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        state.openDocument(at: file)
        state.document.loadMarkdown("changed")
        state.document.isDirty = true

        state.prepareForTermination()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertTrue(state.needsUnsavedFileChangesAlert, "this window still needs the quit alert")
    }

    // MARK: - Duplicate-open detection

    /// Opening a file already open in ANOTHER window focuses that window
    /// instead of opening a duplicate (wired through the shared registry,
    /// like the menu commands).
    func testOpenDocumentAlreadyOpenElsewhereDoesNotDuplicate() throws {
        let dir = try makeTempDir()
        let registry = WindowRegistry.shared
        let s1 = makeState(defaults: try makeDefaults(), store: makeStore(in: dir))
        let s2 = makeState(defaults: try makeDefaults(), store: makeStore(in: dir))
        let w1 = makeWindow()
        let w2 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.attach(window: w2, appState: s2)
        defer {
            registry.unregister(window: w1)
            registry.unregister(window: w2)
        }
        let file = dir.appendingPathComponent("shared.md")
        try "# Shared".write(to: file, atomically: true, encoding: .utf8)
        s1.openDocument(at: file)

        s2.requestOpenDocument(at: file)

        XCTAssertFalse(s2.hasDocument, "the second window focused the first instead of opening a duplicate")
        XCTAssertNil(s2.document.fileURL)
        XCTAssertEqual(s1.document.fileURL, file.standardizedFileURL, "the first window keeps the file")
    }

    // MARK: - Launch prune

    /// Launch prunes backups no persisted window session references
    /// (orphans from cancelled quits / crashes).
    func testLaunchPrunesOrphanedBackups() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let referenced = UUID()
        let orphan = UUID()
        store.stash(content: "referenced", id: referenced)
        store.stash(content: "orphan", id: orphan)
        SessionRestore.persist(
            windows: [WindowSession(untitledBackupID: referenced)],
            defaults: defaults
        )

        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let launchState = makeState(defaults: defaults, store: store)
        registry.restoreSessionOnLaunch(appState: launchState) { _ in }

        XCTAssertEqual(store.restore(id: referenced), "referenced")
        XCTAssertNil(store.restore(id: orphan), "the unreferenced backup was pruned")
        XCTAssertEqual(launchState.pendingRestore?.untitledBackupID, referenced)
    }
}
