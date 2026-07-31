import AppKit
import XCTest
@testable import MDEditor

/// Focus-aware command routing: the registry tracks open windows, retargets
/// global commands (format bus + File menu) at the main window, and stays
/// safe with no windows open.
final class WindowRegistryTests: XCTestCase {
    @MainActor
    private final class FakeFormatTarget: FormatCommandTarget {
        var received: [FormatCommand] = []
        var saveNotifications = 0
        var publishCount = 0
        func handleFormatCommand(_ command: FormatCommand) { received.append(command) }
        func documentDidSave() { saveNotifications += 1 }
        func publishSelectionState() { publishCount += 1 }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorWindowRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @MainActor
    private func makeState() throws -> (AppState, FakeFormatTarget) {
        let state = AppState(userDefaults: try makeDefaults())
        let target = FakeFormatTarget()
        state.formatTarget = target
        return (state, target)
    }

    @MainActor
    func testCommandsRouteToMainWindowOnly() throws {
        let bus = FormatCommandBus()
        let registry = WindowRegistry(bus: bus)
        let (s1, fake1) = try makeState()
        let (s2, fake2) = try makeState()
        let w1 = makeWindow()
        let w2 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.attach(window: w2, appState: s2)

        registry.noteBecameMain(window: w1)
        XCTAssertTrue(registry.mainAppState === s1)
        XCTAssertTrue(bus.target === fake1)
        bus.send(.toggleBold)
        XCTAssertEqual(fake1.received.count, 1)
        XCTAssertEqual(fake2.received.count, 0)

        // Focus moves: commands must follow to the second window.
        registry.noteBecameMain(window: w2)
        XCTAssertTrue(registry.mainAppState === s2)
        XCTAssertTrue(bus.target === fake2)
        bus.send(.toggleItalic)
        XCTAssertEqual(fake1.received.count, 1, "the background window must not receive commands")
        XCTAssertEqual(fake2.received.count, 1)
    }

    @MainActor
    func testClosingMainWindowRetargetsRemainingWindow() throws {
        let bus = FormatCommandBus()
        let registry = WindowRegistry(bus: bus)
        let (s1, fake1) = try makeState()
        let (s2, _) = try makeState()
        let w1 = makeWindow()
        let w2 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.attach(window: w2, appState: s2)
        registry.noteBecameMain(window: w1)
        registry.noteBecameMain(window: w2)

        registry.unregister(window: w2)
        XCTAssertTrue(registry.mainAppState === s1, "the next window in z-order takes over")
        XCTAssertTrue(bus.target === fake1)
        XCTAssertEqual(fake1.publishCount, 2, "selection re-publishes on every retarget")
    }

    @MainActor
    func testClosingLastWindowLeavesNoTarget() throws {
        let bus = FormatCommandBus()
        let registry = WindowRegistry(bus: bus)
        let (s1, _) = try makeState()
        let w1 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.noteBecameMain(window: w1)
        registry.unregister(window: w1)

        XCTAssertNil(registry.mainAppState)
        XCTAssertFalse(bus.hasTarget)
        bus.send(.toggleBold) // must be a safe no-op
    }

    @MainActor
    func testNoWindowsAtAllIsSafeNoOp() {
        let bus = FormatCommandBus()
        let registry = WindowRegistry(bus: bus)
        XCTAssertNil(registry.mainAppState)
        XCTAssertFalse(bus.hasTarget)
        bus.send(.insertTable) // must be a safe no-op
    }

    @MainActor
    func testRecordsTrackRecencyForSessionOrder() throws {
        let registry = WindowRegistry(bus: FormatCommandBus())
        let (s1, _) = try makeState()
        let (s2, _) = try makeState()
        let (s3, _) = try makeState()
        let w1 = makeWindow()
        let w2 = makeWindow()
        let w3 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.attach(window: w2, appState: s2)
        registry.attach(window: w3, appState: s3)
        XCTAssertEqual(registry.registeredAppStates.count, 3)

        registry.noteBecameMain(window: w2)
        XCTAssertTrue(registry.registeredAppStates[0] === s2, "most recently main first (≈ z-order)")
        XCTAssertTrue(registry.registeredAppStates[1] === s1)
    }

    @MainActor
    func testOpenWindowBridgePassesSessionValue() {
        let registry = WindowRegistry(bus: FormatCommandBus())
        var opened: [WindowSession] = []
        registry.openWindowHandler = { opened.append($0) }
        registry.openWindow()
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(opened[0].hasContent, "a fresh window carries no restore data")
    }

    /// WindowGroup(for:) focuses an existing window when asked to open an
    /// already-presented value — equal-content sessions must still be
    /// distinct values to get genuinely new windows.
    func testEmptyWindowSessionsAreUnique() {
        XCTAssertNotEqual(WindowSession(), WindowSession())
    }

    /// Duplicate-open detection: the registry finds the OTHER window already
    /// showing a file, so the opener can focus it instead of duplicating.
    @MainActor
    func testRecordWithOpenFileFindsOtherWindowOnly() throws {
        let registry = WindowRegistry(bus: FormatCommandBus())
        let (s1, _) = try makeState()
        let (s2, _) = try makeState()
        let w1 = makeWindow()
        let w2 = makeWindow()
        registry.attach(window: w1, appState: s1)
        registry.attach(window: w2, appState: s2)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        s1.openDocument(at: file)
        let url = file.standardizedFileURL

        XCTAssertTrue(registry.record(withOpenFile: url, otherThan: s2)?.appState === s1)
        XCTAssertNil(
            registry.record(withOpenFile: url, otherThan: s1),
            "the window holding the file is excluded (same-window re-open is a separate no-op)"
        )
        XCTAssertNil(registry.record(withOpenFile: URL(fileURLWithPath: "/tmp/none-\(UUID().uuidString).md"), otherThan: s2))
    }
}
