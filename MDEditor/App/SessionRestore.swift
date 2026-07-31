import Foundation

/// One window's restorable state: the open file and/or workspace root, or
/// the hot-exit backup of an untitled document.
/// Crosses `openWindow(value:)` (Hashable + Codable) at launch, so each
/// window carries its own restore data.
struct WindowSession: Codable, Hashable {
    /// Unique per instance: `WindowGroup(for:)` focuses an existing window
    /// when asked to open an already-presented value, so equal content must
    /// still compare unequal to get a genuinely new window.
    var id = UUID()
    var fileURL: URL?
    var workspaceRoot: URL?
    /// Hot-exit backup holding this window's untitled document's content
    /// (a UUID into `HotExitStore`). Mutually exclusive with `fileURL` —
    /// a window's document is either file-backed or untitled.
    var untitledBackupID: UUID?

    /// True when there's anything to restore (an empty value marks a plain
    /// new window).
    var hasContent: Bool { fileURL != nil || workspaceRoot != nil || untitledBackupID != nil }

    init(fileURL: URL? = nil, workspaceRoot: URL? = nil, untitledBackupID: UUID? = nil) {
        self.fileURL = fileURL
        self.workspaceRoot = workspaceRoot
        self.untitledBackupID = untitledBackupID
    }
}

/// Persists every open window (document + workspace root) as app-scope
/// security-scoped bookmarks so the session restores across launches
/// (the sandbox otherwise forgets every granted URL on quit).
/// Stale bookmarks resolve to nil and are cleared silently.
enum SessionRestore {
    /// Upper bound on windows reopened at launch.
    static let maxRestoredWindows = 8

    private static let windowsKey = "restore.windows"
    // Legacy single-window keys (pre-multi-window format, migrated on read).
    private static let fileBookmarkKey = "restore.openFileBookmark"
    private static let workspaceBookmarkKey = "restore.workspaceBookmark"

    /// Storage form of one window: bookmark data survives the sandbox. The
    /// untitled backup ID is a plain UUID (backups live in the app's own
    /// container, no bookmark needed); absent in pre-hot-exit sessions and
    /// decodes as nil there.
    private struct StoredWindow: Codable {
        var file: Data?
        var workspace: Data?
        var untitledBackupID: UUID?
    }

    /// Writes the session for all open windows, most-recently-main first;
    /// an empty list clears the entry.
    static func persist(windows: [WindowSession], defaults: UserDefaults = .standard) {
        let stored = windows.map {
            StoredWindow(
                file: $0.fileURL.flatMap(bookmarkData(for:)),
                workspace: $0.workspaceRoot.flatMap(bookmarkData(for:)),
                untitledBackupID: $0.untitledBackupID
            )
        }
        defaults.set(try? JSONEncoder().encode(stored), forKey: windowsKey)
    }

    /// Reads back the persisted windows (entries whose bookmarks all fail to
    /// resolve are dropped silently), capped at `maxRestoredWindows`.
    /// A legacy single-window session migrates on first read.
    static func restoreWindowEntries(defaults: UserDefaults = .standard) -> [WindowSession] {
        if let data = defaults.data(forKey: windowsKey),
           let stored = try? JSONDecoder().decode([StoredWindow].self, from: data) {
            let entries = stored.compactMap { window -> WindowSession? in
                let entry = WindowSession(
                    fileURL: window.file.flatMap(resolve(_:)),
                    workspaceRoot: window.workspace.flatMap(resolve(_:)),
                    untitledBackupID: window.untitledBackupID
                )
                return entry.hasContent ? entry : nil
            }
            return Array(entries.prefix(maxRestoredWindows))
        }
        let legacy = restoreURLs(defaults: defaults)
        guard legacy.file != nil || legacy.workspace != nil else { return [] }
        defaults.removeObject(forKey: fileBookmarkKey)
        defaults.removeObject(forKey: workspaceBookmarkKey)
        return [WindowSession(fileURL: legacy.file, workspaceRoot: legacy.workspace)]
    }

    // MARK: - Legacy single-window format

    /// Writes the legacy single-window session bookmarks; kept for the
    /// migration path (and its tests) — the app persists `windows:` now.
    static func persist(fileURL: URL?, workspaceRoot: URL?, defaults: UserDefaults = .standard) {
        defaults.set(fileURL.flatMap(bookmarkData(for:)), forKey: fileBookmarkKey)
        defaults.set(workspaceRoot.flatMap(bookmarkData(for:)), forKey: workspaceBookmarkKey)
    }

    /// Reads back the legacy single-window URLs (nil when absent or unresolvable).
    static func restoreURLs(defaults: UserDefaults = .standard) -> (file: URL?, workspace: URL?) {
        let file = defaults.data(forKey: fileBookmarkKey).flatMap(resolve(_:))
        let workspace = defaults.data(forKey: workspaceBookmarkKey).flatMap(resolve(_:))
        return (file, workspace)
    }

    // MARK: - Bookmarks

    /// Creates app-scope security-scoped bookmark data for `url`.
    static func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves bookmark data; stale bookmarks resolve to nil (cleared silently).
    static func resolve(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else { return nil }
        return url.standardizedFileURL
    }
}
