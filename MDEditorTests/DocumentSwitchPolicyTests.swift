import XCTest
@testable import MDEditor

/// The pure dirty × autosave × file-URL decision matrix behind document
/// switching and autosave.
final class DocumentSwitchPolicyTests: XCTestCase {
    // MARK: - switchAction

    func testCleanDocumentAlwaysProceeds() {
        for autosave in [true, false] {
            for hasFile in [true, false] {
                XCTAssertEqual(
                    DocumentSwitchPolicy.switchAction(isDirty: false, hasFileURL: hasFile, autosaveEnabled: autosave),
                    .proceed
                )
            }
        }
    }

    func testDirtySavedFileWithAutosaveSavesSilently() {
        XCTAssertEqual(
            DocumentSwitchPolicy.switchAction(isDirty: true, hasFileURL: true, autosaveEnabled: true),
            .saveSilently
        )
    }

    func testDirtyUntitledWithAutosaveAsks() {
        XCTAssertEqual(
            DocumentSwitchPolicy.switchAction(isDirty: true, hasFileURL: false, autosaveEnabled: true),
            .askUser,
            "untitled documents have no location for a silent save"
        )
    }

    func testDirtyWithoutAutosaveAlwaysAsks() {
        for hasFile in [true, false] {
            XCTAssertEqual(
                DocumentSwitchPolicy.switchAction(isDirty: true, hasFileURL: hasFile, autosaveEnabled: false),
                .askUser
            )
        }
    }

    // MARK: - shouldAutosave

    func testShouldAutosaveOnlyWhenDirtySavedAndEnabled() {
        XCTAssertTrue(DocumentSwitchPolicy.shouldAutosave(isDirty: true, hasFileURL: true, autosaveEnabled: true))
        XCTAssertFalse(DocumentSwitchPolicy.shouldAutosave(isDirty: false, hasFileURL: true, autosaveEnabled: true))
        XCTAssertFalse(DocumentSwitchPolicy.shouldAutosave(isDirty: true, hasFileURL: false, autosaveEnabled: true))
        XCTAssertFalse(DocumentSwitchPolicy.shouldAutosave(isDirty: true, hasFileURL: true, autosaveEnabled: false))
    }

    // MARK: - closeAction (red close button)

    func testCleanWindowAlwaysCloses() {
        for autosave in [true, false] {
            for hasFile in [true, false] {
                XCTAssertEqual(
                    DocumentSwitchPolicy.closeAction(isDirty: false, hasFileURL: hasFile, autosaveEnabled: autosave),
                    .close
                )
            }
        }
    }

    func testDirtySavedFileWithAutosaveSavesSilentlyAndCloses() {
        XCTAssertEqual(
            DocumentSwitchPolicy.closeAction(isDirty: true, hasFileURL: true, autosaveEnabled: true),
            .saveSilentlyAndClose
        )
    }

    func testDirtyUntitledWithAutosaveAsksOnClose() {
        XCTAssertEqual(
            DocumentSwitchPolicy.closeAction(isDirty: true, hasFileURL: false, autosaveEnabled: true),
            .askUser,
            "untitled documents have no location for a silent save"
        )
    }

    func testDirtyWithoutAutosaveAsksOnClose() {
        for hasFile in [true, false] {
            XCTAssertEqual(
                DocumentSwitchPolicy.closeAction(isDirty: true, hasFileURL: hasFile, autosaveEnabled: false),
                .askUser
            )
        }
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
