import AppKit
import XCTest
@testable import MDEditor

/// Finder file-open routing (double-click a .md): `application(_:openFiles:)`
/// feeds `WindowRegistry.openFiles`, which queues URLs until the launch
/// window drains them after session restore, then opens each file exactly
/// once — focused when already open, in the key window when idle, in its
/// own window otherwise — and never duplicates a file the session restore
/// is already reopening.
@MainActor
final class FileOpenRoutingTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorFileOpenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // Bookmarks resolve symlink-expanded paths; keep every URL real-path
        // so session-restored and Finder-opened URLs compare equal.
        return dir.resolvingSymlinksInPath()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorFileOpenTests-\(UUID().uuidString)"
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

    private func makeMarkdownFile(in dir: URL, name: String) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        return file.standardizedFileURL
    }

    /// Counts registered windows showing `url` (the exactly-once invariant).
    private func openCount(of url: URL, in registry: WindowRegistry) -> Int {
        registry.registeredAppStates.filter { $0.hasDocument && $0.document.fileURL == url }.count
    }

    /// The launch sequence of WindowRootView.onAppear, replicated headlessly.
    private func simulateLaunchWindow(
        registry: WindowRegistry,
        state: AppState,
        window: NSWindow,
        opened: UnsafeMutablePointer<[WindowSession]>? = nil
    ) {
        registry.attach(window: window, appState: state)
        registry.openWindowHandler = { opened?.pointee.append($0) }
        registry.restoreSessionOnLaunch(appState: state) { opened?.pointee.append($0) }
        state.restoreSessionIfNeeded()
        registry.drainPendingOpenURLs(preferredAppState: state)
    }

    // MARK: - Cold launch

    func testOpenFilesQueueBeforeFirstWindowExists() throws {
        let dir = try makeTempDir()
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: makeStore(in: dir))
        let file = try makeMarkdownFile(in: dir, name: "a.md")

        registry.openFiles([file, file])
        XCTAssertEqual(registry.pendingOpenURLs, [file], "queued once, deduped within the batch")
        XCTAssertTrue(registry.hasPendingOpenURLs)
    }

    func testColdLaunchDrainOpensFileInIdleLaunchWindow() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let file = try makeMarkdownFile(in: dir, name: "a.md")
        registry.openFiles([file])

        let state = makeState(defaults: defaults, store: store)
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: makeWindow(), opened: &opened)

        XCTAssertEqual(state.document.fileURL, file, "the queued file opens in the launch window")
        XCTAssertEqual(openCount(of: file, in: registry), 1)
        XCTAssertTrue(opened.isEmpty, "no extra window for a single file with an idle launch window")
        XCTAssertFalse(registry.hasPendingOpenURLs)
    }

    /// The file was open in the previous session and restores into the
    /// launch window: the Finder open focuses it instead of duplicating.
    func testDrainFocusesFileRestoredInSameWindow() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let file = try makeMarkdownFile(in: dir, name: "a.md")
        SessionRestore.persist(windows: [WindowSession(fileURL: file)], defaults: defaults)
        registry.openFiles([file])

        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: window, opened: &opened)

        XCTAssertEqual(state.document.fileURL, file, "session restore opened the file")
        XCTAssertEqual(openCount(of: file, in: registry), 1, "exactly once — never a second copy")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(window.isVisible, "the restored window is focused for the Finder open")
    }

    /// The file restores into ANOTHER window (a later session entry): the
    /// drain must leave it to that window, and a late duplicate focuses it.
    func testDrainSkipsFileRestoredInAnotherWindow() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let fileA = try makeMarkdownFile(in: dir, name: "a.md")
        let fileB = try makeMarkdownFile(in: dir, name: "b.md")
        SessionRestore.persist(windows: [WindowSession(fileURL: fileA), WindowSession(fileURL: fileB)], defaults: defaults)
        registry.openFiles([fileB])

        let launch = makeState(defaults: defaults, store: store)
        var fannedOut: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: launch, window: makeWindow(), opened: &fannedOut)

        XCTAssertEqual(launch.document.fileURL, fileA, "the launch window restores the first session entry")
        XCTAssertEqual(fannedOut.count, 1, "the second session entry fans out to its own window")
        XCTAssertEqual(fannedOut[0].fileURL, fileB)
        XCTAssertEqual(openCount(of: fileB, in: registry), 0, "B waits for its restored window — not opened twice")

        // The fanned-out window attaches and restores B (WindowRootView path).
        let second = makeState(defaults: defaults, store: store, restore: fannedOut[0])
        let windowB = makeWindow()
        registry.attach(window: windowB, appState: second)
        second.restoreSessionIfNeeded()
        XCTAssertEqual(second.document.fileURL, fileB)

        registry.openFiles([fileB])
        XCTAssertEqual(openCount(of: fileB, in: registry), 1, "a late duplicate open focuses instead")
        XCTAssertTrue(windowB.isVisible)
    }

    /// A cold-launch multi-select: the first file takes the idle launch
    /// window, each further file gets its own window via the bridge.
    func testColdLaunchMultipleFilesRouteIndividually() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let fileA = try makeMarkdownFile(in: dir, name: "a.md")
        let fileB = try makeMarkdownFile(in: dir, name: "b.md")
        registry.openFiles([fileA, fileB])

        let state = makeState(defaults: defaults, store: store)
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: makeWindow(), opened: &opened)

        XCTAssertEqual(state.document.fileURL, fileA)
        XCTAssertEqual(opened.compactMap(\.fileURL), [fileB], "the second file opens its own window")
        XCTAssertEqual(openCount(of: fileA, in: registry), 1)
    }

    // MARK: - Steady state (app already launched)

    func testSteadyStateDuplicateFocusesExistingWindow() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let file = try makeMarkdownFile(in: dir, name: "a.md")
        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: window, opened: &opened)
        state.openDocument(at: file)
        XCTAssertFalse(window.isVisible)

        registry.openFiles([file])

        XCTAssertTrue(window.isVisible, "already-open files focus their window")
        XCTAssertEqual(openCount(of: file, in: registry), 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testSteadyStateIdleKeyWindowOpensThere() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let file = try makeMarkdownFile(in: dir, name: "a.md")
        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        simulateLaunchWindow(registry: registry, state: state, window: window)
        registry.noteBecameMain(window: window)

        registry.openFiles([file])

        XCTAssertEqual(state.document.fileURL, file, "an idle key window (welcome state) takes the file")
        XCTAssertEqual(openCount(of: file, in: registry), 1)
    }

    /// With no MAIN window (e.g. the app launched in the background), the
    /// frontmost idle window is still the target — not a new window.
    func testSteadyStateNoMainWindowFallsBackToFrontmostIdle() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let file = try makeMarkdownFile(in: dir, name: "a.md")
        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: window, opened: &opened)
        XCTAssertNil(registry.mainAppState, "no window became main")

        registry.openFiles([file])

        XCTAssertEqual(state.document.fileURL, file, "the frontmost idle window takes the file")
        XCTAssertTrue(opened.isEmpty, "no extra window opens")
        XCTAssertEqual(openCount(of: file, in: registry), 1)
    }

    func testSteadyStateBusyKeyWindowOpensNewWindow() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let fileA = try makeMarkdownFile(in: dir, name: "a.md")
        let fileB = try makeMarkdownFile(in: dir, name: "b.md")
        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        var opened: [WindowSession] = []
        simulateLaunchWindow(registry: registry, state: state, window: window, opened: &opened)
        registry.noteBecameMain(window: window)
        state.openDocument(at: fileA)
        opened.removeAll()

        registry.openFiles([fileB])

        XCTAssertEqual(state.document.fileURL, fileA, "the busy window keeps its document")
        XCTAssertEqual(opened.compactMap(\.fileURL), [fileB], "the new file gets its own window")
    }

    /// With no window bridge available (no window ever appeared), a file
    /// that can't route stays queued for the next drain instead of dropping.
    func testUnroutableFileStaysQueued() throws {
        let dir = try makeTempDir()
        let defaults = try makeDefaults()
        let store = makeStore(in: dir)
        let registry = WindowRegistry(bus: FormatCommandBus(), hotExitStore: store)
        let fileA = try makeMarkdownFile(in: dir, name: "a.md")
        let fileB = try makeMarkdownFile(in: dir, name: "b.md")
        let state = makeState(defaults: defaults, store: store)
        let window = makeWindow()
        registry.attach(window: window, appState: state)
        registry.restoreSessionOnLaunch(appState: state) { _ in }
        state.openDocument(at: fileA)
        // No openWindowHandler: the bridge isn't installed.

        registry.openFiles([fileB])

        XCTAssertEqual(registry.pendingOpenURLs, [fileB], "kept queued until a window bridge exists")
    }
}
