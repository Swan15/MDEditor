import XCTest
@testable import MDEditor

/// The full document-lifecycle decision matrix: state (none / untitled /
/// file) × dirty × autosave for every entry point (new, open, ⌘W, window
/// close, quit). Table-driven, one row per meaningful combination.
final class DocumentSwitchPolicyTests: XCTestCase {
    private typealias Policy = DocumentSwitchPolicy
    private typealias State = DocumentSwitchPolicy.DocumentState

    // MARK: - newDocumentAction / openDocumentAction (switching away)

    /// (state, isDirty, autosaveEnabled, expected) — New and Open share the
    /// switching rule: clean/none proceeds, a dirty autosaved file saves
    /// silently, anything else dirty asks.
    private let switchCases: [(State, Bool, Bool, DocumentSwitchPolicy.SwitchAction)] = [
        (.none, false, false, .proceed),
        (.none, false, true, .proceed),
        (.none, true, false, .proceed), // none is never dirty; defensive
        (.none, true, true, .proceed),
        (.untitled, false, false, .proceed), // empty untitled is clean
        (.untitled, false, true, .proceed),
        (.untitled, true, false, .askUser),
        (.untitled, true, true, .askUser), // untitled can never save silently
        (.file, false, false, .proceed),
        (.file, false, true, .proceed),
        (.file, true, false, .askUser),
        (.file, true, true, .saveSilently),
    ]

    func testNewDocumentMatrix() {
        for (state, dirty, autosave, expected) in switchCases {
            XCTAssertEqual(
                Policy.newDocumentAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                expected,
                "new: \(state) dirty=\(dirty) autosave=\(autosave)"
            )
        }
    }

    func testOpenDocumentMatrix() {
        for (state, dirty, autosave, expected) in switchCases {
            XCTAssertEqual(
                Policy.openDocumentAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                expected,
                "open: \(state) dirty=\(dirty) autosave=\(autosave)"
            )
        }
    }

    // MARK: - closeDocumentAction (⌘W → the empty state, never a phantom untitled)

    func testCloseDocumentMatrix() {
        let cases: [(State, Bool, Bool, DocumentSwitchPolicy.CloseDocumentAction)] = [
            (.none, false, false, .closeToEmpty),
            (.none, false, true, .closeToEmpty),
            (.none, true, true, .closeToEmpty),
            (.untitled, false, false, .closeToEmpty), // empty untitled closes immediately
            (.untitled, false, true, .closeToEmpty),
            (.untitled, true, false, .askUser),
            (.untitled, true, true, .askUser), // ⌘W always asks about untitled content
            (.file, false, false, .closeToEmpty),
            (.file, false, true, .closeToEmpty),
            (.file, true, false, .askUser),
            (.file, true, true, .saveSilently),
        ]
        for (state, dirty, autosave, expected) in cases {
            XCTAssertEqual(
                Policy.closeDocumentAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                expected,
                "⌘W: \(state) dirty=\(dirty) autosave=\(autosave)"
            )
        }
    }

    // MARK: - windowCloseAction / quitAction (the no-prompt hot-exit path)

    func testWindowCloseMatrix() {
        let cases: [(State, Bool, Bool, DocumentSwitchPolicy.WindowCloseAction)] = [
            (.none, false, false, .close),
            (.none, false, true, .close),
            (.none, true, true, .close),
            (.untitled, false, false, .close), // empty untitled closes immediately
            (.untitled, false, true, .close),
            (.untitled, true, false, .stashHotExitAndClose), // never asks
            (.untitled, true, true, .stashHotExitAndClose),
            (.file, false, false, .close),
            (.file, false, true, .close),
            (.file, true, false, .askUser),
            (.file, true, true, .saveSilentlyAndClose),
        ]
        for (state, dirty, autosave, expected) in cases {
            XCTAssertEqual(
                Policy.windowCloseAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                expected,
                "window close: \(state) dirty=\(dirty) autosave=\(autosave)"
            )
        }
    }

    /// Per-window quit uses the exact window-close rule (hot exit on quit).
    func testQuitActionMatchesWindowCloseMatrix() {
        for state in [State.none, .untitled, .file] {
            for dirty in [false, true] {
                for autosave in [false, true] {
                    XCTAssertEqual(
                        Policy.quitAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                        Policy.windowCloseAction(state: state, isDirty: dirty, autosaveEnabled: autosave),
                        "quit: \(state) dirty=\(dirty) autosave=\(autosave)"
                    )
                }
            }
        }
    }

    // MARK: - shouldAutosave

    func testShouldAutosaveOnlyWhenDirtySavedAndEnabled() {
        XCTAssertTrue(Policy.shouldAutosave(isDirty: true, hasFileURL: true, autosaveEnabled: true))
        XCTAssertFalse(Policy.shouldAutosave(isDirty: false, hasFileURL: true, autosaveEnabled: true))
        XCTAssertFalse(Policy.shouldAutosave(isDirty: true, hasFileURL: false, autosaveEnabled: true))
        XCTAssertFalse(Policy.shouldAutosave(isDirty: true, hasFileURL: true, autosaveEnabled: false))
    }
}

/// The persisted preferences flag (default ON, UserDefaults-backed).
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testAutosaveDefaultsToOn() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertTrue(settings.autosaveEnabled)
    }

    func testAutosaveTogglePersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.autosaveEnabled = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autosaveEnabled)
    }
}
