import XCTest
@testable import MDEditor

/// The file-system watcher: event→rescan mapping and debounce coalescing.
/// Timing tests use short intervals and generous margins to stay stable.
@MainActor
final class FileSystemWatcherTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeOnExit(_ dir: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Event → rescan mapping

    func testContentChangeRescansTheDirectoryItself() {
        let dir = URL(fileURLWithPath: "/tmp/workspace")
        let changed = FileSystemWatcher.directoriesToRescan(watchedDirectory: dir, event: .write)
        XCTAssertEqual(changed, [dir])
    }

    func testDeleteRescansDirectoryAndParent() {
        let dir = URL(fileURLWithPath: "/tmp/workspace/sub")
        let changed = FileSystemWatcher.directoriesToRescan(watchedDirectory: dir, event: .delete)
        XCTAssertEqual(Set(changed.map(\.path)), ["/tmp/workspace", "/tmp/workspace/sub"])
    }

    func testRenameRescansDirectoryAndParent() {
        let dir = URL(fileURLWithPath: "/tmp/workspace/sub")
        let changed = FileSystemWatcher.directoriesToRescan(watchedDirectory: dir, event: .rename)
        XCTAssertEqual(Set(changed.map(\.path)), ["/tmp/workspace", "/tmp/workspace/sub"])
    }

    // MARK: - Debounce coalescing

    func testFlushCoalescesPendingDirectories() {
        let watcher = FileSystemWatcher(debounceInterval: .seconds(3600))
        var delivered: [Set<URL>] = []
        watcher.onChange = { delivered.append($0) }

        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        watcher.noteChanged(directory: a)
        watcher.noteChanged(directory: b)
        watcher.noteChanged(directory: a)
        watcher.flushPending()

        XCTAssertEqual(delivered, [[a, b]], "one delivery with the union of directories")

        watcher.flushPending()
        XCTAssertEqual(delivered.count, 1, "empty flushes don't fire")
    }

    func testDebounceDeliversOnceAfterQuietPeriod() async throws {
        let watcher = FileSystemWatcher(debounceInterval: .milliseconds(50))
        var delivered: [Set<URL>] = []
        watcher.onChange = { delivered.append($0) }

        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        watcher.noteChanged(directory: a)
        watcher.noteChanged(directory: b)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered, [[a, b]])
    }

    // MARK: - Real watching (tolerant)

    func testRealWatchDetectsNewFile() async throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let watcher = FileSystemWatcher(debounceInterval: .milliseconds(50))
        var delivered: Set<URL> = []
        watcher.onChange = { delivered.formUnion($0) }

        watcher.watch(directory: dir)
        try Data().write(to: dir.appendingPathComponent("new.md"))

        // Poll generously: fs event delivery is not real-time.
        for _ in 0..<40 where delivered.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(delivered.contains(dir.standardizedFileURL))
    }

    func testUnwatchStopsDelivery() async throws {
        let dir = try makeTempDir()
        removeOnExit(dir)
        let watcher = FileSystemWatcher(debounceInterval: .milliseconds(50))
        var delivered: Set<URL> = []
        watcher.onChange = { delivered.formUnion($0) }

        watcher.watch(directory: dir)
        watcher.unwatch(directory: dir)
        try Data().write(to: dir.appendingPathComponent("ignored.md"))

        // A false pass is harmless; a delivery here would be a real failure.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(delivered.isEmpty)
    }
}
