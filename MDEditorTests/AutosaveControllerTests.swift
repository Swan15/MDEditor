import XCTest
@testable import MDEditor

/// Idle autosave: fires once after the quiet period, coalesces rapid edits,
/// and never touches untitled documents or runs while disabled.
@MainActor
final class AutosaveControllerTests: XCTestCase {
    /// Records save invocations (the controller's save closure is the seam;
    /// no real disk writes happen here).
    private final class SaveRecorder {
        var count = 0
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorAutosaveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeFixture(
        delay: Duration = .milliseconds(60)
    ) throws -> (DocumentModel, AppSettings, AutosaveController, SaveRecorder) {
        let document = DocumentModel()
        let settings = AppSettings(defaults: try makeDefaults())
        let controller = AutosaveController()
        let recorder = SaveRecorder()
        controller.configure(document: document, settings: settings, delay: delay) {
            recorder.count += 1
        }
        return (document, settings, controller, recorder)
    }

    func testSavesAfterIdleDelay() async throws {
        let (document, _, controller, recorder) = try makeFixture()
        document.fileURL = URL(fileURLWithPath: "/tmp/autosave.md")

        document.isDirty = true
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(recorder.count, 1)
        withExtendedLifetime(controller) {}
    }

    func testRapidEditsCoalesceIntoOneSave() async throws {
        let (document, _, controller, recorder) = try makeFixture()
        document.fileURL = URL(fileURLWithPath: "/tmp/autosave.md")

        for _ in 0..<5 {
            document.isDirty = true
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(recorder.count, 1, "the idle timer restarts on every edit")
        withExtendedLifetime(controller) {}
    }

    func testNoSaveForUntitledDocument() async throws {
        let (document, _, controller, recorder) = try makeFixture()
        document.isDirty = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.count, 0)
        withExtendedLifetime(controller) {}
    }

    func testNoSaveWhenDisabled() async throws {
        let (document, settings, controller, recorder) = try makeFixture()
        settings.autosaveEnabled = false
        document.fileURL = URL(fileURLWithPath: "/tmp/autosave.md")

        document.isDirty = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.count, 0)
        withExtendedLifetime(controller) {}
    }

    func testPendingSaveCancelledWhenMarkedClean() async throws {
        let (document, _, controller, recorder) = try makeFixture()
        document.fileURL = URL(fileURLWithPath: "/tmp/autosave.md")

        document.isDirty = true
        try await Task.sleep(for: .milliseconds(20))
        document.isDirty = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.count, 0, "a manual save before the idle deadline wins")
        withExtendedLifetime(controller) {}
    }
}
