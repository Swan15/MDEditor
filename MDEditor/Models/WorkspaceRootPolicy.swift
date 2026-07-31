import Foundation

/// Decides whether opening a file should change the workspace root
/// (pure; the grants, scanning and watching live in `FileOperations`).
enum WorkspaceRootPolicy {
    /// The folder that should become the workspace root when `fileURL` is
    /// opened, or nil to keep the current workspace.
    ///
    /// VSCode rule: a file inside the current root changes nothing (a
    /// sidebar click always lands here); a file outside it — or any file
    /// with no workspace open — adopts its parent folder, so ⌘O / recents /
    /// session restore land in a sidebar that shows the opened file.
    static func rootForOpenedFile(currentRoot: URL?, openedFileURL: URL) -> URL? {
        let file = openedFileURL.standardizedFileURL
        // Canonical folder form (no trailing slash, except the filesystem
        // root) — the same shape a folder picked in NSOpenPanel comes in.
        var parentPath = file.deletingLastPathComponent().path
        if parentPath.count > 1, parentPath.hasSuffix("/") { parentPath.removeLast() }
        let parent = URL(fileURLWithPath: parentPath)
        guard let currentRoot else { return parent }
        let rootPath = currentRoot.path.hasSuffix("/") ? currentRoot.path : currentRoot.path + "/"
        return file.path.hasPrefix(rootPath) ? nil : parent
    }
}
