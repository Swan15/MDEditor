import XCTest
@testable import MDEditor

/// Hot-exit backup store: stash / restore / delete / prune over an injected
/// temporary directory (the app itself uses the container-default store).
final class HotExitStoreTests: XCTestCase {
    private func makeStore() throws -> (HotExitStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorHotExitTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (HotExitStore(directory: dir), dir)
    }

    func testStashCreatesDirectoryAndRestoreRoundTrips() throws {
        let (store, dir) = try makeStore()
        let id = UUID()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing written before the first stash")

        store.stash(content: "# Hello\n\nsome *markdown*", id: id)
        XCTAssertEqual(store.restore(id: id), "# Hello\n\nsome *markdown*")
    }

    func testStashOverwritesPreviousBackupWithSameID() throws {
        let (store, _) = try makeStore()
        let id = UUID()
        store.stash(content: "first", id: id)
        store.stash(content: "second", id: id)
        XCTAssertEqual(store.restore(id: id), "second", "re-stashing refreshes the content in place")
    }

    func testMultipleIDsStayIndependent() throws {
        let (store, _) = try makeStore()
        let a = UUID()
        let b = UUID()
        store.stash(content: "doc A", id: a)
        store.stash(content: "doc B", id: b)
        XCTAssertEqual(store.restore(id: a), "doc A")
        XCTAssertEqual(store.restore(id: b), "doc B")
    }

    func testRestoreMissingBackupReturnsNilNotCrash() throws {
        let (store, _) = try makeStore()
        XCTAssertNil(store.restore(id: UUID()), "a missing backup file reads back as nil")
    }

    func testDeleteRemovesBackup() throws {
        let (store, _) = try makeStore()
        let id = UUID()
        store.stash(content: "bye", id: id)
        store.delete(id: id)
        XCTAssertNil(store.restore(id: id))
    }

    func testDeleteMissingBackupIsNoOp() throws {
        let (store, _) = try makeStore()
        store.delete(id: UUID()) // must not throw / crash
    }

    func testPruneDropsOrphansKeepsReferenced() throws {
        let (store, dir) = try makeStore()
        let keep = UUID()
        let orphanA = UUID()
        let orphanB = UUID()
        store.stash(content: "referenced", id: keep)
        store.stash(content: "orphan A", id: orphanA)
        store.stash(content: "orphan B", id: orphanB)
        // Non-backup files in the directory are left alone.
        let stray = dir.appendingPathComponent("notes.txt")
        try "keep me".write(to: stray, atomically: true, encoding: .utf8)

        store.prune(except: [keep])

        XCTAssertEqual(store.restore(id: keep), "referenced")
        XCTAssertNil(store.restore(id: orphanA))
        XCTAssertNil(store.restore(id: orphanB))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testPruneOnMissingDirectoryIsNoOp() throws {
        let (store, _) = try makeStore()
        store.prune(except: []) // directory was never created; must not crash
    }
}
