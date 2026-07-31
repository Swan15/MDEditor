import Foundation

/// Pure decision logic for the document lifecycle (new/open/close/quit) and
/// autosave, kept headless so the whole matrix is unit-testable.
///
/// The rules follow VSCode: switching away from or closing a dirty document
/// asks (or saves silently when autosave covers it), but window close and
/// quit never prompt for an untitled document — its content is stashed in a
/// hot-exit backup instead and restored on relaunch.
enum DocumentSwitchPolicy {
    /// What a window currently presents.
    enum DocumentState: Equatable {
        /// No document open (the welcome view shows).
        case none
        /// A document that was never saved to disk.
        case untitled
        /// A document backed by a file on disk.
        case file
    }

    /// How to treat the current document before replacing it with another
    /// one (File ▸ New, Open…, recents, sidebar click).
    enum SwitchAction: Equatable {
        /// Nothing unsaved: switch right away.
        case proceed
        /// Autosave covers the dirty, already-saved file: write silently first.
        case saveSilently
        /// Dirty and not silently saveable: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The switching rule, shared by New and Open: autosave-on + file on
    /// disk saves silently; anything else dirty asks; clean (or no document)
    /// always proceeds.
    private static func switchAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> SwitchAction {
        guard isDirty, state != .none else { return .proceed }
        return state == .file && autosaveEnabled ? .saveSilently : .askUser
    }

    /// File ▸ New: replace the current document with a fresh untitled one.
    static func newDocumentAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> SwitchAction {
        switchAction(state: state, isDirty: isDirty, autosaveEnabled: autosaveEnabled)
    }

    /// File ▸ Open… / recents / sidebar click: replace the current document
    /// with the chosen file (same dirty handling as New).
    static func openDocumentAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> SwitchAction {
        switchAction(state: state, isDirty: isDirty, autosaveEnabled: autosaveEnabled)
    }

    /// How to treat the current document on File ▸ Close Document (⌘W).
    /// Afterwards the window has NO document (the empty/welcome state) —
    /// closing never resets to a phantom untitled document.
    enum CloseDocumentAction: Equatable {
        /// Clean (or nothing open): close to the empty state right away.
        case closeToEmpty
        /// Autosave covers the dirty, already-saved file: write silently
        /// first (falling back to asking when the silent save fails).
        case saveSilently
        /// Dirty and not silently saveable: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The ⌘W rule — the same dirty handling as switching documents (an
    /// explicit close always asks about unsaved content; only window close
    /// and quit stash untitled documents silently).
    static func closeDocumentAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> CloseDocumentAction {
        guard isDirty, state != .none else { return .closeToEmpty }
        return state == .file && autosaveEnabled ? .saveSilently : .askUser
    }

    /// How to treat a window's document when the user closes the window
    /// (red button) or the app quits — the no-prompt path for untitled
    /// documents (VSCode hot exit).
    enum WindowCloseAction: Equatable {
        /// Nothing unsaved (or no document): close right away.
        case close
        /// Autosave covers the dirty, already-saved file: write silently, then
        /// close (falling back to asking when the silent save fails).
        case saveSilentlyAndClose
        /// Dirty untitled document: serialize it into the hot-exit backup
        /// store and close WITHOUT asking — it restores on relaunch.
        case stashHotExitAndClose
        /// Dirty file without autosave coverage: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The window-close rule: autosave-on + file on disk saves silently;
    /// a dirty untitled document stashes a hot-exit backup (never asks); a
    /// dirty file without autosave asks; clean always closes.
    static func windowCloseAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> WindowCloseAction {
        guard isDirty, state != .none else { return .close }
        switch state {
        case .none: return .close // unreachable: none is never dirty
        case .untitled: return .stashHotExitAndClose
        case .file: return autosaveEnabled ? .saveSilentlyAndClose : .askUser
        }
    }

    /// The per-window quit rule — identical to the window-close rule
    /// (untitled documents hot-exit; only dirty files without autosave ask).
    static func quitAction(state: DocumentState, isDirty: Bool, autosaveEnabled: Bool) -> WindowCloseAction {
        windowCloseAction(state: state, isDirty: isDirty, autosaveEnabled: autosaveEnabled)
    }

    /// Autosave fires only for dirty documents that exist on disk.
    static func shouldAutosave(isDirty: Bool, hasFileURL: Bool, autosaveEnabled: Bool) -> Bool {
        autosaveEnabled && isDirty && hasFileURL
    }

    /// One open document's lifecycle state for the multi-window quit decision.
    struct DocumentDirtyState: Equatable {
        var state: DocumentState
        var isDirty: Bool
    }

    /// How to treat the whole session (every open window) when the app is
    /// asked to quit.
    enum SessionQuitAction: Equatable {
        /// Nothing to prepare anywhere: terminate right away.
        case terminate
        /// No window needs an alert, but at least one needs preparation
        /// (silent save and/or untitled hot-exit stash) before terminating.
        case prepareAndTerminate
        /// At least one dirty file without autosave needs the Save /
        /// Don't Save / Cancel alert.
        case askUser
    }

    /// The multi-window quitting rule: any dirty file without autosave
    /// coverage forces the alert flow; otherwise dirty documents are saved
    /// silently and dirty untitled documents stashed as hot-exit backups.
    /// Clean sessions (or no windows) terminate.
    static func quitAction(documents: [DocumentDirtyState], autosaveEnabled: Bool) -> SessionQuitAction {
        var needsPreparation = false
        for document in documents {
            switch quitAction(state: document.state, isDirty: document.isDirty, autosaveEnabled: autosaveEnabled) {
            case .askUser:
                return .askUser
            case .saveSilentlyAndClose, .stashHotExitAndClose:
                needsPreparation = true
            case .close:
                break
            }
        }
        return needsPreparation ? .prepareAndTerminate : .terminate
    }
}
