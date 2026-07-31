import Foundation

/// Watches workspace directories for external changes (Finder edits, git
/// checkouts, …) so the sidebar can rescan them.
///
/// One `DispatchSource` per watched directory; the workspace root is always
/// watched, folders are watched as they expand. Events are debounced
/// (~300 ms) and delivered on the main actor as a set of directories to
/// rescan. Sources are cancelled when unwatched or on teardown, so no file
/// descriptors or dispatche sources leak across root changes.
@MainActor
final class FileSystemWatcher {
    /// Debounce window for coalescing bursts of file-system events.
    let debounceInterval: Duration

    /// Called with the directories that changed since the last delivery.
    var onChange: ((Set<URL>) -> Void)?

    /// Watched directory → dispatch source (keyed by standardized URL).
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]

    /// Directories accumulated since the last flush.
    private var pending: Set<URL> = []

    /// The scheduled debounce flush.
    private var flushTask: Task<Void, Never>?

    init(debounceInterval: Duration = .milliseconds(300)) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        flushTask?.cancel()
        for source in sources.values { source.cancel() }
    }

    /// Starts watching a directory (no-op when already watched or unreadable).
    func watch(directory: URL) {
        let directory = directory.standardizedFileURL
        guard sources[directory] == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source targets the main queue; the class is main-actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = source.data
                let changed = Self.directoriesToRescan(watchedDirectory: directory, event: event)
                if event.contains(.delete) || event.contains(.rename) {
                    // The directory itself is gone: drop its watch.
                    self.unwatch(directory: directory)
                }
                for url in changed {
                    self.noteChanged(directory: url)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[directory] = source
    }

    /// Stops watching one directory.
    func unwatch(directory: URL) {
        let directory = directory.standardizedFileURL
        guard let source = sources.removeValue(forKey: directory) else { return }
        source.cancel()
    }

    /// Stops watching everything and drops pending events (root change / close).
    func stopWatchingAll() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    /// Records a changed directory and schedules a coalesced delivery.
    func noteChanged(directory: URL) {
        pending.insert(directory.standardizedFileURL)
        flushTask?.cancel()
        flushTask = Task { [weak self, debounceInterval] in
            do { try await Task.sleep(for: debounceInterval) } catch { return }
            self?.flushPending()
        }
    }

    /// Delivers the pending directories immediately (timer target + test seam).
    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let changed = pending
        pending.removeAll()
        onChange?(changed)
    }

    /// Event → rescan mapping: content changes rescan the directory itself;
    /// when the directory vanished, its parent rescans too (to drop the node).
    nonisolated static func directoriesToRescan(
        watchedDirectory: URL,
        event: DispatchSource.FileSystemEvent
    ) -> Set<URL> {
        if event.contains(.delete) || event.contains(.rename) {
            return [watchedDirectory, watchedDirectory.deletingLastPathComponent()]
        }
        return [watchedDirectory]
    }
}
