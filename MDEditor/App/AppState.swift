import Foundation
import Observation

/// Per-window state: the window's workspace (folder mode) and open document.
/// One instance per editor window; preferences (`AppSettings`) are shared
/// across all windows.
@MainActor @Observable
final class AppState {
    /// Root folder of the workspace. `nil` means single-file mode.
    /// Mutate via `openWorkspace(at:)` / `closeWorkspace()` so the file tree,
    /// watcher and persisted session stay in sync.
    var workspaceRoot: URL?

    /// The document currently loaded in the editor.
    var document = DocumentModel()

    /// Security-scoped folder access held for the session (image loading
    /// and asset creation next to single-file documents).
    let securityScope = SecurityScope()

    /// Persisted preferences (shown in the Settings scene); shared by every
    /// window (injected), created per instance only in tests.
    let settings: AppSettings

    /// Folder-mode file tree + watcher.
    let workspace: WorkspaceModel

    /// Idle autosave for dirty documents with a file on disk.
    let autosaveController: AutosaveController

    /// Guards the one-shot session restore on launch.
    var didRestoreSession = false

    /// Restore data handed to this window at creation (nil = plain new
    /// window; the launch window receives the first persisted entry from
    /// `WindowRegistry.restoreSessionOnLaunch`).
    var pendingRestore: WindowSession?

    /// This window's editor, installed by the coordinator. Global commands
    /// reach it via the bus only while this window is main; per-window
    /// callbacks (e.g. `documentDidSave`) use this directly.
    @ObservationIgnored weak var formatTarget: FormatCommandTarget?

    /// Defaults backing settings and session restore (injectable for tests).
    @ObservationIgnored let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, settings: AppSettings? = nil, restore: WindowSession? = nil) {
        self.userDefaults = userDefaults
        self.settings = settings ?? AppSettings(defaults: userDefaults)
        self.pendingRestore = restore
        self.workspace = WorkspaceModel()
        self.autosaveController = AutosaveController()
        // The style engine derives its fonts from the preferences; the
        // editor coordinator observes them for live restyle on change.
        StyleEngine.fontSettings = self.settings
        AppSettings.applyAppearance(self.settings.appearance)
        autosaveController.configure(document: document, settings: self.settings) { [weak self] in
            self?.saveDocumentSilently()
        }
    }
}
