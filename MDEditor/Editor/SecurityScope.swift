import Foundation

/// Holds security-scoped folder access for the app session.
///
/// Sandbox reality: opening a single `.md` via `NSOpenPanel` grants access to
/// THAT file only — sibling images can't be read, and an `assets/` folder
/// can't be created next to the file. The remedy is a one-time folder pick
/// (`NSOpenPanel` in directory mode); the picked URL is then kept "accessed"
/// for the rest of the session.
///
/// Lifetime choice: grants are deliberately held until process exit, never
/// balanced with `stopAccessingSecurityScopedResource`. Balancing start/stop
/// per read is fragile (images are re-decoded on redraw and re-read on every
/// save), the kernel caps the number of held resources high enough for a
/// folder or two, and process exit reclaims everything. So "leak-free" here
/// means: hold few, hold deliberately, document it.
///
/// Used from the main thread only (all callers are UI flows and tests).
final class SecurityScope {
    /// Folder URLs currently held open for the session.
    private(set) var heldRoots: [URL] = []

    /// Whether the folder-access prompt was already shown this session
    /// (the "ask once" guard for the passive on-load prompt).
    private(set) var didPromptForFolderAccess = false

    /// Records that the folder-access prompt has been shown.
    func notePromptShown() {
        didPromptForFolderAccess = true
    }

    /// True when `url` sits inside a folder already held for the session.
    func covers(_ url: URL) -> Bool {
        heldRoots.contains { root in
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return url.path.hasPrefix(rootPath)
        }
    }

    /// Ensures access to `url`, acquiring a security scope when needed.
    ///
    /// A `false` return is NOT necessarily a failure: it also means the URL
    /// is readable without a scope (unsandboxed runs, already-granted files).
    /// Callers should still attempt the read and judge by its result.
    @discardableResult
    func ensureAccess(to url: URL) -> Bool {
        if covers(url) { return true }
        guard url.startAccessingSecurityScopedResource() else { return false }
        heldRoots.append(url.standardizedFileURL)
        return true
    }
}
