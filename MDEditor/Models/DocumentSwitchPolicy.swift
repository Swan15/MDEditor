import Foundation

/// Pure decision logic for document switching and autosave, kept headless
/// so the whole matrix is unit-testable.
enum DocumentSwitchPolicy {
    /// How to treat the current document before opening another one.
    enum SwitchAction: Equatable {
        /// Nothing unsaved: switch right away.
        case proceed
        /// Autosave covers the dirty, already-saved file: write silently first.
        case saveSilently
        /// Dirty and not silently saveable: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The switching rule: autosave-on + file on disk saves silently;
    /// anything else dirty asks; clean always proceeds.
    static func switchAction(isDirty: Bool, hasFileURL: Bool, autosaveEnabled: Bool) -> SwitchAction {
        guard isDirty else { return .proceed }
        return autosaveEnabled && hasFileURL ? .saveSilently : .askUser
    }

    /// Autosave fires only for dirty documents that exist on disk.
    static func shouldAutosave(isDirty: Bool, hasFileURL: Bool, autosaveEnabled: Bool) -> Bool {
        autosaveEnabled && isDirty && hasFileURL
    }

    /// How to treat a window's document when the user closes the window.
    enum CloseAction: Equatable {
        /// Nothing unsaved: close right away.
        case close
        /// Autosave covers the dirty, already-saved file: write silently, then
        /// close (falling back to asking when the silent save fails).
        case saveSilentlyAndClose
        /// Dirty and not silently saveable: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The window-close rule — the same dirty handling as switching documents:
    /// autosave-on + file on disk saves silently; anything else dirty asks;
    /// clean always closes.
    static func closeAction(isDirty: Bool, hasFileURL: Bool, autosaveEnabled: Bool) -> CloseAction {
        guard isDirty else { return .close }
        return autosaveEnabled && hasFileURL ? .saveSilentlyAndClose : .askUser
    }

    /// How to treat the current document when the app is asked to quit.
    enum QuitAction: Equatable {
        /// Nothing unsaved: terminate right away.
        case terminate
        /// Autosave covers the dirty, already-saved file: write silently, then
        /// terminate (falling back to asking when the silent save fails).
        case saveSilentlyAndTerminate
        /// Dirty and not silently saveable: ask (Save / Don't Save / Cancel).
        case askUser
    }

    /// The quitting rule — the same dirty handling as switching documents:
    /// autosave-on + file on disk saves silently; anything else dirty asks;
    /// clean always terminates.
    static func quitAction(isDirty: Bool, hasFileURL: Bool, autosaveEnabled: Bool) -> QuitAction {
        guard isDirty else { return .terminate }
        return autosaveEnabled && hasFileURL ? .saveSilentlyAndTerminate : .askUser
    }

    /// One open document's dirty state for the multi-window quit decision.
    struct DocumentDirtyState: Equatable {
        var isDirty: Bool
        var hasFileURL: Bool
    }

    /// How to treat the whole session (every open window) when the app is
    /// asked to quit.
    enum SessionQuitAction: Equatable {
        /// Nothing unsaved anywhere: terminate right away.
        case terminate
        /// Every dirty document is autosave-covered: save them all silently,
        /// then terminate (falling back to asking when a silent save fails).
        case saveSilentlyAndTerminate
        /// At least one document needs the Save / Don't Save / Cancel alert.
        case askUser
    }

    /// The multi-window quitting rule: any document that can't be saved
    /// silently forces the alert flow; otherwise all dirty documents are
    /// written silently. Clean sessions (or no windows) terminate.
    static func quitAction(documents: [DocumentDirtyState], autosaveEnabled: Bool) -> SessionQuitAction {
        var needsSilentSave = false
        for document in documents where document.isDirty {
            guard autosaveEnabled && document.hasFileURL else { return .askUser }
            needsSilentSave = true
        }
        return needsSilentSave ? .saveSilentlyAndTerminate : .terminate
    }
}
