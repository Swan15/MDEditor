import XCTest
@testable import MDEditor

/// Multi-window quit policy over the whole session: every open window's
/// document feeds one decision (the alert flow itself is manual QA — see
/// TESTING.md). With hot exit, a dirty untitled document never blocks the
/// quit — only a dirty file without autosave forces the alert.
final class QuitPolicyTests: XCTestCase {
    private typealias Policy = DocumentSwitchPolicy
    private typealias State = DocumentSwitchPolicy.DocumentState

    private func doc(_ state: State, _ isDirty: Bool) -> DocumentSwitchPolicy.DocumentDirtyState {
        DocumentSwitchPolicy.DocumentDirtyState(state: state, isDirty: isDirty)
    }

    func testNoWindowsTerminates() {
        for autosave in [false, true] {
            XCTAssertEqual(
                Policy.quitAction(documents: [], autosaveEnabled: autosave),
                .terminate
            )
        }
    }

    func testAllCleanTerminates() {
        for autosave in [false, true] {
            XCTAssertEqual(
                Policy.quitAction(
                    documents: [doc(.none, false), doc(.untitled, false), doc(.file, false)],
                    autosaveEnabled: autosave
                ),
                .terminate,
                "autosave \(autosave)"
            )
        }
    }

    /// Every dirty document is autosave-covered: all save silently, no alert.
    func testDirtySavedFilesWithAutosavePrepareSilently() {
        XCTAssertEqual(
            Policy.quitAction(
                documents: [doc(.file, false), doc(.file, true), doc(.file, true)],
                autosaveEnabled: true
            ),
            .prepareAndTerminate
        )
    }

    /// Hot exit: a dirty untitled document stashes a backup instead of
    /// asking — with autosave on or off, and even mixed with clean windows.
    func testDirtyUntitledStashesWithoutAsking() {
        for autosave in [false, true] {
            XCTAssertEqual(
                Policy.quitAction(
                    documents: [doc(.untitled, true)],
                    autosaveEnabled: autosave
                ),
                .prepareAndTerminate,
                "autosave \(autosave)"
            )
            XCTAssertEqual(
                Policy.quitAction(
                    documents: [doc(.file, false), doc(.untitled, true), doc(.none, false)],
                    autosaveEnabled: autosave
                ),
                .prepareAndTerminate,
                "autosave \(autosave)"
            )
        }
    }

    /// A dirty file without autosave coverage is the ONLY case that forces
    /// the alert flow — one such window is enough, even when every other
    /// window can be prepared silently.
    func testDirtyFileWithoutAutosaveForcesAsk() {
        XCTAssertEqual(
            Policy.quitAction(
                documents: [doc(.file, true)],
                autosaveEnabled: false
            ),
            .askUser
        )
        XCTAssertEqual(
            Policy.quitAction(
                documents: [doc(.untitled, true), doc(.file, true)],
                autosaveEnabled: false
            ),
            .askUser,
            "the untitled stashes, but the uncovered dirty file still asks"
        )
    }

    /// Mixed preparation: untitled stashes + autosaved files save silently.
    func testMixedStashAndSilentSavePrepares() {
        XCTAssertEqual(
            Policy.quitAction(
                documents: [doc(.untitled, true), doc(.file, true)],
                autosaveEnabled: true
            ),
            .prepareAndTerminate
        )
    }
}
