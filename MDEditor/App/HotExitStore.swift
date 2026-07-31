import Foundation

/// Hot-exit backup store for untitled documents (VSCode-style hot exit).
///
/// When a window holding a dirty untitled document closes (red button) or
/// the app quits, the document's serialized Markdown is stashed here and the
/// window's session entry references the backup's UUID. On relaunch the
/// backup is restored as an untitled document — no Save / Don't Save alert
/// ever appears for untitled content on close/quit.
///
/// Backups live inside the app's container (`Application Support/MDEditor/
/// UntitledBackups/<uuid>.md`), so no user-granted permission is needed.
/// A backup is deleted when its document is saved to a real file, explicitly
/// discarded (Don't Save), closed clean, or pruned as an orphan at launch
/// (not referenced by any persisted window session).
struct HotExitStore {
    /// Directory holding the backup files (injectable for tests).
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store the app uses; tests inject a temporary directory instead.
    static let shared = HotExitStore(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MDEditor/UntitledBackups", isDirectory: true)
    )

    /// Writes `content` as the backup for `id`, replacing any previous one.
    /// Content is the document's serialized Markdown — restore feeds it back
    /// through the normal parser/builder, no separate format.
    func stash(content: String, id: UUID) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? content.write(to: fileURL(for: id), atomically: true, encoding: .utf8)
    }

    /// The stashed Markdown for `id`; nil when no (readable) backup exists.
    func restore(id: UUID) -> String? {
        try? String(contentsOf: fileURL(for: id), encoding: .utf8)
    }

    /// Deletes the backup for `id` (missing files are ignored).
    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Deletes every backup whose UUID is not in `except` — orphans left
    /// behind by sessions that no longer reference them (e.g. a cancelled
    /// quit after stashing, or a crash before the session was persisted).
    func prune(except keep: Set<UUID>) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            guard file.pathExtension == "md",
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !keep.contains(id) else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".md")
    }
}
