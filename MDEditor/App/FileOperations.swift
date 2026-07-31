import AppKit
import UniformTypeIdentifiers

/// File-menu and sidebar file operations: new/open/save/close on the current
/// document, workspace management, recents and session persistence.
///
/// Anything that replaces or closes the current document goes through the
/// lifecycle policy first (`prepareToSwitchDocument` / `closeDocument`), so
/// unsaved content is never lost silently. Closing a document (⌘W) leaves
/// the window in the empty state (welcome view) — never a phantom untitled.
extension AppState {
    /// Content types accepted by the open/save panels.
    private var markdownContentTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
    }

    // MARK: - New / Open (with switching rules)

    /// File → New: a fresh empty document (dirty handling first).
    @MainActor func requestNewDocument() {
        guard prepareToSwitchDocument(DocumentSwitchPolicy.newDocumentAction(
            state: documentState,
            isDirty: isDirtyForPolicy,
            autosaveEnabled: settings.autosaveEnabled
        )) else { return }
        presentFreshUntitled()
    }

    /// File → Open…: pick a Markdown file and load it (dirty handling first).
    @MainActor func requestOpenDocument() {
        guard prepareToSwitchDocument(DocumentSwitchPolicy.openDocumentAction(
            state: documentState,
            isDirty: isDirtyForPolicy,
            autosaveEnabled: settings.autosaveEnabled
        )) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = workspaceRoot
        guard panel.runModal() == .OK, let pickedURL = panel.url else { return }
        let url = pickedURL.standardizedFileURL
        // Already open in another window: focus it instead of duplicating.
        if let record = WindowRegistry.shared.record(withOpenFile: url, otherThan: self) {
            record.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard !hasDocument || url != document.fileURL else { return }
        openDocument(at: url)
    }

    /// Opens a specific file (sidebar click, Open Recent): dirty handling first.
    @MainActor func requestOpenDocument(at url: URL) {
        let url = url.standardizedFileURL
        // Re-opening the file that's already open here is a no-op.
        if hasDocument && url == document.fileURL { return }
        // Already open in another window: focus it instead of duplicating.
        if let record = WindowRegistry.shared.record(withOpenFile: url, otherThan: self) {
            record.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard prepareToSwitchDocument(DocumentSwitchPolicy.openDocumentAction(
            state: documentState,
            isDirty: isDirtyForPolicy,
            autosaveEnabled: settings.autosaveEnabled
        )) else { return }
        openDocument(at: url)
    }

    /// Loads the Markdown file at `url` into the editor.
    @MainActor func openDocument(at url: URL) {
        let url = url.standardizedFileURL
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            // The replaced document's untitled backup (if any) is discarded —
            // it was clean or the user already chose Don't Save to get here.
            discardUntitledBackup()
            document.fileURL = url
            document.isDirty = false
            document.loadMarkdown(source)
            hasDocument = true
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            adoptWorkspaceForOpenedFile(url)
            workspace.reveal(url)
            persistSession()
        } catch {
            presentError(error, message: "Couldn’t open “\(url.lastPathComponent)”.")
        }
    }

    // MARK: - Save

    /// File → Save: serialize the editor content and write it out, asking
    /// for a location first when the document was never saved.
    @MainActor func saveDocument() {
        guard hasDocument, let markdown = document.serializedMarkdown() else { return }
        if let url = document.fileURL {
            write(markdown, to: url)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = markdownContentTypes
            panel.nameFieldStringValue = "Untitled.md"
            panel.directoryURL = workspaceRoot
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write(markdown, to: url)
        }
    }

    /// File → Save As…: always asks for a (new) location and moves the
    /// document's file URL there.
    @MainActor func saveDocumentAs() {
        guard hasDocument, let markdown = document.serializedMarkdown() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = markdownContentTypes
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "Untitled.md"
        panel.directoryURL = document.fileURL?.deletingLastPathComponent() ?? workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(markdown, to: url)
    }

    /// Silent write to the current location (autosave, pre-switch save).
    /// Never prompts; on failure the document stays dirty and the next edit retries.
    @MainActor func saveDocumentSilently() {
        guard let url = document.fileURL, let markdown = document.serializedMarkdown() else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            document.isDirty = false
        } catch {
            // Autosave must never interrupt the user.
        }
    }

    /// Writes the document out to `url` (internal for hot-exit lifecycle
    /// tests; the menu flows go through `saveDocument` / `saveDocumentAs`).
    @MainActor func write(_ markdown: String, to url: URL) {
        let url = url.standardizedFileURL
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            document.fileURL = url
            document.isDirty = false
            // Saving an untitled document to a real file retires its backup.
            discardUntitledBackup()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            workspace.reveal(url)
            persistSession()
            // A fresh save location lets the editor re-resolve images that
            // were placeholders while the document had no folder.
            formatTarget?.documentDidSave()
        } catch {
            presentError(error, message: "Couldn’t save “\(url.lastPathComponent)”.")
        }
    }

    // MARK: - Close

    /// File → Close Document (⌘W): dirty handling, then the window goes to
    /// the empty state (welcome view). It NEVER resets to a phantom
    /// untitled document.
    @MainActor func closeDocument() {
        guard hasDocument else { return }
        switch DocumentSwitchPolicy.closeDocumentAction(
            state: documentState,
            isDirty: isDirtyForPolicy,
            autosaveEnabled: settings.autosaveEnabled
        ) {
        case .closeToEmpty:
            enterNoneState()
        case .saveSilently:
            saveDocumentSilently()
            // A failed silent save leaves the document dirty: ask instead of
            // losing the changes.
            guard !document.isDirty else { return askToCloseDocument() }
            enterNoneState()
        case .askUser:
            askToCloseDocument()
        }
    }

    /// Save / Don't Save / Cancel for ⌘W on a dirty document. Save writes
    /// (with the location panel for untitled) and the close still happens;
    /// Don't Save discards (including any hot-exit backup); Cancel keeps
    /// the document open.
    @MainActor private func askToCloseDocument() {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(document.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument()
            // A cancelled save panel leaves the document dirty: stay.
            if !document.isDirty { enterNoneState() }
        case .alertSecondButtonReturn:
            enterNoneState()
        default:
            break
        }
    }

    /// The empty state: no document, welcome view. The caller already saved
    /// or explicitly discarded the content; any hot-exit backup goes with
    /// the document (closing clean deletes it).
    @MainActor private func enterNoneState() {
        discardUntitledBackup()
        document.fileURL = nil
        document.isDirty = false
        document.pendingMarkdown = nil
        hasDocument = false
        persistSession()
    }

    /// A fresh, empty untitled document (File ▸ New lands here, and only
    /// here — closing never produces one).
    @MainActor private func presentFreshUntitled() {
        discardUntitledBackup()
        document.fileURL = nil
        document.isDirty = false
        document.loadMarkdown("")
        hasDocument = true
        persistSession()
    }

    // MARK: - Workspace

    /// File → Open Folder…: pick a workspace root (dirty handling first;
    /// the current document stays open).
    @MainActor func requestOpenFolder() {
        guard prepareToSwitchDocument(DocumentSwitchPolicy.openDocumentAction(
            state: documentState,
            isDirty: isDirtyForPolicy,
            autosaveEnabled: settings.autosaveEnabled
        )) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as the workspace."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(at: url)
    }

    /// Sets the workspace root and starts watching it. Access is held for
    /// the session (required for bookmark-restored roots).
    @MainActor func openWorkspace(at url: URL) {
        let root = url.standardizedFileURL
        securityScope.ensureAccess(to: root)
        workspaceRoot = root
        workspace.openWorkspace(at: root)
        persistSession()
    }

    /// Closes the workspace, back to single-file mode.
    @MainActor func closeWorkspace() {
        workspaceRoot = nil
        workspace.closeWorkspace()
        persistSession()
    }

    /// A file opened from outside the sidebar (⌘O, recents, welcome,
    /// session restore) adopts its parent folder as the workspace root —
    /// the sidebar then shows the opened file, VSCode-style. A file inside
    /// the current root changes nothing. Sandbox: single-file opens grant
    /// access to the .md only, so adopting can need the folder grant —
    /// asked once per folder per session; declining still opens the file,
    /// the workspace just stays as it was.
    @MainActor
    private func adoptWorkspaceForOpenedFile(_ fileURL: URL) {
        guard let root = WorkspaceRootPolicy.rootForOpenedFile(currentRoot: workspaceRoot, openedFileURL: fileURL) else { return }
        if hasFolderAccess(root) {
            openWorkspace(at: root)
            workspace.reveal(fileURL)
            return
        }
        // Ask once per folder per session, async so the open itself never
        // blocks on (or queues behind) the panel.
        guard !securityScope.didPrompt(for: root) else { return }
        securityScope.notePromptShown(for: root)
        let armedRoot = workspaceRoot
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentFolderAccessPanel(defaultingTo: root) != nil else { return }
            // The window may have moved on while the panel was up: adopt
            // only when this file is still the document, the workspace
            // wasn't changed meanwhile, and the grant actually made the
            // folder readable.
            guard self.document.fileURL == fileURL,
                  self.workspaceRoot == armedRoot,
                  WorkspaceRootPolicy.rootForOpenedFile(currentRoot: self.workspaceRoot, openedFileURL: fileURL) == root,
                  self.hasFolderAccess(root) else { return }
            self.openWorkspace(at: root)
            self.workspace.reveal(fileURL)
        }
    }

    /// True when `folder` can actually be enumerated: granted this session,
    /// or simply readable (unsandboxed runs, the app's own container). A
    /// probe beats `ensureAccess`'s return, which is also false for plain
    /// non-security-scoped URLs that read fine.
    private func hasFolderAccess(_ folder: URL) -> Bool {
        securityScope.covers(folder) || (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// The one-time folder grant: the sandbox gives single-file documents
    /// access to the .md only; showing the folder in the sidebar and
    /// loading images next to it needs the folder itself. Returns the
    /// picked folder (access held for the session), nil on cancel.
    @MainActor
    @discardableResult
    func presentFolderAccessPanel(defaultingTo folder: URL?) -> URL? {
        if let folder {
            securityScope.notePromptShown(for: folder)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "MDEditor needs access to this folder to show it in the sidebar and load images."
        panel.prompt = "Grant Access"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        securityScope.ensureAccess(to: url)
        return url.standardizedFileURL
    }

    // MARK: - Sidebar file management

    /// Context-menu New File: creates "untitled.md" (deduped) in the folder,
    /// then opens it (dirty handling for the current document first).
    @MainActor func sidebarNewFile(in folderURL: URL) {
        do {
            let url = try FileTreeOperations.createMarkdownFile(in: folderURL)
            workspace.rescan(directory: folderURL)
            workspace.reveal(url)
            requestOpenDocument(at: url)
        } catch {
            presentError(error, message: "Couldn’t create the file.")
        }
    }

    /// Context-menu New Folder: creates "untitled folder" (deduped) and reveals it.
    @MainActor func sidebarNewFolder(in folderURL: URL) {
        do {
            let url = try FileTreeOperations.createFolder(in: folderURL)
            workspace.rescan(directory: folderURL)
            workspace.reveal(url)
        } catch {
            presentError(error, message: "Couldn’t create the folder.")
        }
    }

    /// Context-menu Rename…: small alert with a name field; the open document
    /// follows renames of itself or an ancestor folder.
    @MainActor func sidebarRename(_ node: FileTreeNode) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(node.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = node.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != node.name, !newName.contains("/") else { return }
        do {
            let newURL = try FileTreeOperations.rename(at: node.url, to: newName)
            remapOpenDocument(from: node.url, to: newURL)
            workspace.rescan(directory: node.url.deletingLastPathComponent())
            workspace.reveal(newURL)
            persistSession()
        } catch {
            presentError(error, message: "Couldn’t rename “\(node.name)”.")
        }
    }

    /// Context-menu Move to Trash: confirms first, always trashes (never unlinks).
    @MainActor func sidebarDelete(_ node: FileTreeNode) {
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = node.isFolder
            ? "The folder and its contents will be moved to the Trash."
            : "You can restore the file from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileTreeOperations.moveToTrash(at: node.url)
            // The open document (or an ancestor of it) was trashed: keep the
            // content but detach from the gone file, so saving re-asks a location.
            if let fileURL = document.fileURL, fileURL == node.url || isDescendant(fileURL, of: node.url) {
                document.fileURL = nil
                document.isDirty = true
            }
            workspace.rescan(directory: node.url.deletingLastPathComponent())
            persistSession()
        } catch {
            presentError(error, message: "Couldn’t move “\(node.name)” to the Trash.")
        }
    }

    /// Context-menu Reveal in Finder.
    @MainActor func sidebarReveal(_ node: FileTreeNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    // MARK: - Switching rules

    /// Applies a switching-policy action (dirty-document handling) before
    /// replacing the current document. Returns false when the user
    /// cancelled — the caller must abort its action.
    @MainActor
    private func prepareToSwitchDocument(_ action: DocumentSwitchPolicy.SwitchAction) -> Bool {
        switch action {
        case .proceed:
            return true
        case .saveSilently:
            saveDocumentSilently()
            return true
        case .askUser:
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes to “\(document.title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let wasUntitled = document.fileURL == nil
                saveDocument()
                // A saved untitled document becomes a real file: stay on it
                // instead of switching away (VSCode rule). A cancelled save
                // panel also stays.
                if wasUntitled { return false }
                // A failed save leaves the document dirty: abort.
                return !document.isDirty
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Session restore

    /// One-shot launch restore: reopens the workspace and document carried in
    /// this window's `pendingRestore` entry — a file on disk, or an untitled
    /// document from its hot-exit backup. Missing files/backups are skipped
    /// silently and the session is re-persisted without them.
    @MainActor func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        guard let entry = pendingRestore else { return }
        pendingRestore = nil
        if let root = entry.workspaceRoot {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
                openWorkspace(at: root)
            }
        }
        if let file = entry.fileURL, FileManager.default.fileExists(atPath: file.path) {
            securityScope.ensureAccess(to: file)
            openDocument(at: file)
        } else if let backupID = entry.untitledBackupID,
                  let content = hotExitStore.restore(id: backupID) {
            // Hot exit: the untitled document comes back with its content,
            // marked dirty — it exists nowhere on disk. The backup stays
            // (referenced by this window) until save / discard / clean close.
            document.fileURL = nil
            document.loadMarkdown(content)
            document.isDirty = true
            untitledBackupID = backupID
            hasDocument = true
        }
        // Rewrites the bookmarks, clearing anything that failed to resolve.
        persistSession()
    }

    /// This window's persisted session entry: the open file, or the untitled
    /// document's hot-exit backup, plus the workspace root.
    var windowSession: WindowSession {
        WindowSession(
            fileURL: hasDocument ? document.fileURL : nil,
            workspaceRoot: workspaceRoot,
            untitledBackupID: hasDocument ? untitledBackupID : nil
        )
    }

    /// Persists the session for every open window (this window included).
    /// Windows are recorded most-recently-main first (≈ z-order). A window
    /// that isn't registered yet persists just itself when nothing else is
    /// registered (tests), and nothing during a running session — writing
    /// then could drop windows that haven't finished restoring.
    func persistSession() {
        let states = WindowRegistry.shared.registeredAppStates
        guard !states.isEmpty else {
            SessionRestore.persist(windows: [windowSession], defaults: userDefaults)
            return
        }
        guard states.contains(where: { $0 === self }) else { return }
        WindowRegistry.shared.persistSession(defaults: userDefaults)
    }

    // MARK: - Helpers

    /// Points the open document at a renamed location (itself or an ancestor).
    private func remapOpenDocument(from oldURL: URL, to newURL: URL) {
        guard let fileURL = document.fileURL else { return }
        if fileURL == oldURL {
            document.fileURL = newURL
        } else if isDescendant(fileURL, of: oldURL) {
            let suffix = String(fileURL.path.dropFirst(oldURL.path.count)) // keeps the leading "/"
            document.fileURL = URL(fileURLWithPath: newURL.path + suffix).standardizedFileURL
        }
    }

    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let ancestorPath = ancestor.path.hasSuffix("/") ? ancestor.path : ancestor.path + "/"
        return url.path.hasPrefix(ancestorPath)
    }

    @MainActor
    private func presentError(_ error: Error, message: String) {
        let alert = NSAlert(error: error)
        alert.messageText = message
        alert.runModal()
    }
}
