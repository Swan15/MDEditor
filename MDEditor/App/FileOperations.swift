import AppKit
import UniformTypeIdentifiers

/// File-menu and sidebar file operations: open/save/close on the current
/// document, workspace management, recents and session persistence.
///
/// Anything that replaces or backgrounds the current document goes through
/// the switching policy first (`prepareToSwitchDocument`), so unsaved
/// content is never lost silently.
extension AppState {
    /// Content types accepted by the open/save panels.
    private var markdownContentTypes: [UTType] {
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
    }

    // MARK: - New / Open (with switching rules)

    /// File → New: a fresh empty document (dirty handling first).
    @MainActor func requestNewDocument() {
        guard prepareToSwitchDocument() else { return }
        resetToUntitled()
    }

    /// File → Open…: pick a Markdown file and load it (dirty handling first).
    @MainActor func requestOpenDocument() {
        guard prepareToSwitchDocument() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url)
    }

    /// Opens a specific file (sidebar click, Open Recent): dirty handling first.
    @MainActor func requestOpenDocument(at url: URL) {
        // Re-opening the file that's already open is a no-op.
        guard url.standardizedFileURL != document.fileURL else { return }
        guard prepareToSwitchDocument() else { return }
        openDocument(at: url)
    }

    /// Loads the Markdown file at `url` into the editor.
    @MainActor func openDocument(at url: URL) {
        let url = url.standardizedFileURL
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            document.fileURL = url
            document.isDirty = false
            document.loadMarkdown(source)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
        guard let markdown = document.serializedMarkdown() else { return }
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
        guard let markdown = document.serializedMarkdown() else { return }
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

    @MainActor private func write(_ markdown: String, to url: URL) {
        let url = url.standardizedFileURL
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            document.fileURL = url
            document.isDirty = false
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

    /// File → Close Document (⌘W): dirty handling, then back to a fresh
    /// untitled document (the editor stays mounted).
    @MainActor func closeDocument() {
        guard prepareToSwitchDocument() else { return }
        resetToUntitled()
    }

    @MainActor private func resetToUntitled() {
        document.fileURL = nil
        document.isDirty = false
        document.loadMarkdown("")
        persistSession()
    }

    // MARK: - Workspace

    /// File → Open Folder…: pick a workspace root (dirty handling first;
    /// the current document stays open).
    @MainActor func requestOpenFolder() {
        guard prepareToSwitchDocument() else { return }
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

    /// Applies the dirty-document switching policy before replacing (or
    /// backgrounding) the current document. Returns false when the user
    /// cancelled — the caller must abort its action.
    @MainActor
    private func prepareToSwitchDocument() -> Bool {
        switch DocumentSwitchPolicy.switchAction(
            isDirty: document.isDirty,
            hasFileURL: document.fileURL != nil,
            autosaveEnabled: settings.autosaveEnabled
        ) {
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
                saveDocument()
                // A cancelled save panel leaves the document dirty: abort.
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
    /// this window's `pendingRestore` entry. Missing files/folders are skipped
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
        }
        // Rewrites the bookmarks, clearing anything that failed to resolve.
        persistSession()
    }

    /// Persists the session for every open window (this window included).
    /// Windows are recorded most-recently-main first (≈ z-order). A window
    /// that isn't registered yet persists just itself when nothing else is
    /// registered (tests), and nothing during a running session — writing
    /// then could drop windows that haven't finished restoring.
    func persistSession() {
        let states = WindowRegistry.shared.registeredAppStates
        guard !states.isEmpty else {
            SessionRestore.persist(
                windows: [WindowSession(fileURL: document.fileURL, workspaceRoot: workspaceRoot)],
                defaults: userDefaults
            )
            return
        }
        guard states.contains(where: { $0 === self }) else { return }
        SessionRestore.persist(
            windows: states.map { WindowSession(fileURL: $0.document.fileURL, workspaceRoot: $0.workspaceRoot) },
            defaults: userDefaults
        )
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
