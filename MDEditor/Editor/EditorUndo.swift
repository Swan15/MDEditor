// UndoManager's closure API predates Swift concurrency; registrations and
// invocations here are all confined to the main thread. `@preconcurrency`
// keeps newer compilers from flagging the (safe) captures.
@preconcurrency import AppKit

/// Snapshot-based undo for storage mutations performed outside `NSTextView`'s
/// own editing paths (format commands and editing behaviors).
///
/// Before a mutation, the whole attributed string plus the selection are
/// captured; undoing restores them through `setAttributedString`, which
/// re-triggers styling, dirty marking and statistics via the text-storage
/// delegate, exactly like a normal edit.
///
/// Limits: the snapshot is the entire document (fine for typical Markdown
/// files), and redo restores the *pre-mutation* selection rather than the
/// exact post-mutation cursor. Native typing undo is unaffected; callers
/// should bracket mutations with `NSTextView.breakUndoCoalescing()` so typing
/// groups never merge across a command.
enum EditorUndo {
    /// Box silencing sendability diagnostics for the selection-restore
    /// closure, which is only ever invoked on the main thread (undo
    /// registration and invocation here are main-thread confined). Captured
    /// strongly by the undo handler, so its lifetime is never in question.
    private final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Registers the storage's current content and selection as one undo step.
    static func registerUndo(
        storage: NSTextStorage,
        selection: NSRange,
        undoManager: UndoManager?,
        actionName: String,
        restoreSelection: ((NSRange) -> Void)? = nil
    ) {
        guard let undoManager else { return }
        let snapshot = NSAttributedString(attributedString: storage)
        let restoreSelection = restoreSelection.map { UncheckedSendableBox($0) }
        undoManager.registerUndo(withTarget: storage) { storage in
            restore(
                snapshot, selection: selection, on: storage,
                undoManager: undoManager, actionName: actionName,
                restoreSelection: restoreSelection
            )
        }
        undoManager.setActionName(actionName)
    }

    /// Restores a snapshot and registers the inverse operation. Registration
    /// performed while the manager is undoing lands on the redo stack (and
    /// vice versa), which is what makes redo work.
    private static func restore(
        _ snapshot: NSAttributedString,
        selection: NSRange,
        on storage: NSTextStorage,
        undoManager: UndoManager,
        actionName: String,
        restoreSelection: UncheckedSendableBox<(NSRange) -> Void>?
    ) {
        let inverse = NSAttributedString(attributedString: storage)
        undoManager.registerUndo(withTarget: storage) { storage in
            restore(
                inverse, selection: selection, on: storage,
                undoManager: undoManager, actionName: actionName,
                restoreSelection: restoreSelection
            )
        }
        undoManager.setActionName(actionName)
        storage.setAttributedString(snapshot)
        restoreSelection?.value(selection)
    }
}
