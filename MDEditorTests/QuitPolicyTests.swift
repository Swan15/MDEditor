import XCTest
@testable import MDEditor

/// Quit-time dirty-document policy (the alert flow itself is manual QA —
/// see TESTING.md). Same matrix as document switching: autosave covers
/// dirty files on disk, everything else dirty asks, clean always quits.
final class QuitPolicyTests: XCTestCase {
    func testCleanDocumentAlwaysTerminates() {
        for hasFileURL in [false, true] {
            for autosaveEnabled in [false, true] {
                XCTAssertEqual(
                    DocumentSwitchPolicy.quitAction(
                        isDirty: false, hasFileURL: hasFileURL, autosaveEnabled: autosaveEnabled
                    ),
                    .terminate,
                    "hasFileURL \(hasFileURL), autosave \(autosaveEnabled)"
                )
            }
        }
    }

    func testDirtySavedFileWithAutosaveSavesSilently() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(isDirty: true, hasFileURL: true, autosaveEnabled: true),
            .saveSilentlyAndTerminate
        )
    }

    func testDirtySavedFileWithAutosaveOffAsks() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(isDirty: true, hasFileURL: true, autosaveEnabled: false),
            .askUser
        )
    }

    /// An untitled document can never be saved silently, even with autosave on.
    func testDirtyUntitledAlwaysAsks() {
        for autosaveEnabled in [false, true] {
            XCTAssertEqual(
                DocumentSwitchPolicy.quitAction(
                    isDirty: true, hasFileURL: false, autosaveEnabled: autosaveEnabled
                ),
                .askUser,
                "autosave \(autosaveEnabled)"
            )
        }
    }
}

/// Multi-window quit policy over the whole session: every open window's
/// document feeds one decision (the alert flow itself is manual QA — see
/// TESTING.md).
final class SessionQuitPolicyTests: XCTestCase {
    private func doc(_ isDirty: Bool, _ hasFileURL: Bool) -> DocumentSwitchPolicy.DocumentDirtyState {
        DocumentSwitchPolicy.DocumentDirtyState(isDirty: isDirty, hasFileURL: hasFileURL)
    }

    func testNoWindowsTerminates() {
        for autosave in [false, true] {
            XCTAssertEqual(
                DocumentSwitchPolicy.quitAction(documents: [], autosaveEnabled: autosave),
                .terminate
            )
        }
    }

    func testAllCleanTerminates() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(
                documents: [doc(false, false), doc(false, true)],
                autosaveEnabled: true
            ),
            .terminate
        )
    }

    /// Every dirty document is autosave-covered: all save silently, no alert.
    func testMultipleDirtySavedFilesWithAutosaveSaveSilently() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(
                documents: [doc(false, true), doc(true, true), doc(true, true)],
                autosaveEnabled: true
            ),
            .saveSilentlyAndTerminate
        )
    }

    /// One window needing the alert is enough, even when others could save
    /// silently.
    func testSingleDirtyUntitledForcesAsk() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(
                documents: [doc(true, true), doc(true, false)],
                autosaveEnabled: true
            ),
            .askUser
        )
    }

    func testAutosaveOffWithAnyDirtyAsks() {
        XCTAssertEqual(
            DocumentSwitchPolicy.quitAction(
                documents: [doc(false, false), doc(true, true)],
                autosaveEnabled: false
            ),
            .askUser
        )
    }
}
