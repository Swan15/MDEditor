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

    /// The document currently loaded in the editor. The model always exists
    /// (the editor, autosave and status bar bind to it once); whether the
    /// window HAS a document is `hasDocument` — with none open, the welcome
    /// view takes the editor's place and the model holds no content.
    var document = DocumentModel()

    /// True when the window presents a document; false shows the VSCode-style
    /// welcome view (the "none" state — a new window starts here, and
    /// File ▸ Close Document (⌘W) returns to it).
    var hasDocument = false

    /// Hot-exit backup holding this window's untitled document's content
    /// (written when a dirty untitled document's window closes or the app
    /// quits; deleted on save, explicit Don't Save, or clean close).
    var untitledBackupID: UUID?

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

    /// Hot-exit backup storage (injected directory in tests).
    let hotExitStore: HotExitStore

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

    init(
        userDefaults: UserDefaults = .standard,
        settings: AppSettings? = nil,
        restore: WindowSession? = nil,
        hotExitStore: HotExitStore = .shared
    ) {
        self.userDefaults = userDefaults
        self.settings = settings ?? AppSettings(defaults: userDefaults)
        self.pendingRestore = restore
        self.hotExitStore = hotExitStore
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

    // MARK: - Lifecycle state

    /// What the window presents right now (the lifecycle policy's input).
    var documentState: DocumentSwitchPolicy.DocumentState {
        guard hasDocument else { return .none }
        return document.fileURL == nil ? .untitled : .file
    }

    /// Dirty flag for lifecycle decisions: an untitled document counts as
    /// dirty only while it holds any content (VSCode rule — an empty
    /// untitled document is clean), a file-backed document uses the edited
    /// flag, and the none state is never dirty.
    var isDirtyForPolicy: Bool {
        switch documentState {
        case .none: return false
        case .file: return document.isDirty
        case .untitled: return documentHasContent
        }
    }

    /// True when the untitled document holds any (non-whitespace) content.
    private var documentHasContent: Bool {
        guard let markdown = document.serializedMarkdown() else { return false }
        return !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Hot-exit backups

    /// Serializes the untitled document into the hot-exit store (creating
    /// its backup ID on first stash, reusing it afterwards). No-op when the
    /// window has no untitled document with content.
    func stashUntitledBackup() {
        guard documentState == .untitled, let content = document.serializedMarkdown() else { return }
        let id = untitledBackupID ?? UUID()
        hotExitStore.stash(content: content, id: id)
        untitledBackupID = id
    }

    /// Deletes the untitled document's hot-exit backup, if any (save to a
    /// real file, explicit Don't Save, or a clean close). Idempotent.
    func discardUntitledBackup() {
        if let id = untitledBackupID {
            hotExitStore.delete(id: id)
            untitledBackupID = nil
        }
    }

    /// Gets this window's document ready for the app to terminate without
    /// asking: a dirty file covered by autosave saves silently; a dirty
    /// untitled document stashes its hot-exit backup; an untitled document
    /// that was emptied since its backup was stashed drops the stale backup.
    func prepareForTermination() {
        switch documentState {
        case .none:
            break
        case .file:
            if document.isDirty && settings.autosaveEnabled {
                saveDocumentSilently()
            }
        case .untitled:
            if isDirtyForPolicy {
                stashUntitledBackup()
            } else {
                discardUntitledBackup()
            }
        }
    }

    /// True when a dirty file document still needs the user's Save /
    /// Don't Save / Cancel decision (autosave off, or a failed silent save).
    var needsUnsavedFileChangesAlert: Bool {
        documentState == .file && document.isDirty
    }
}
