import AppKit

/// Application delegate: quit-time unsaved-changes protection across every
/// open window (VSCode-style hot exit).
///
/// Quitting checks all registered windows: clean sessions (or none) quit
/// directly; autosave-covered dirty files save silently; dirty untitled
/// documents are stashed into the hot-exit backup store WITHOUT asking
/// (they restore on relaunch); only dirty files without autosave get a
/// Save / Don't Save / Cancel alert per window, delivered asynchronously
/// via `.terminateLater` + `reply(toApplicationShouldTerminate:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared preferences, wired from the SwiftUI app once they exist.
    var settings: AppSettings?

    /// Decides whether the app may terminate by running the multi-document
    /// quit policy over every open window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let states = WindowRegistry.shared.registeredAppStates
        let autosaveEnabled = settings?.autosaveEnabled ?? true
        switch DocumentSwitchPolicy.quitAction(
            documents: states.map {
                DocumentSwitchPolicy.DocumentDirtyState(
                    state: $0.documentState,
                    isDirty: $0.isDirtyForPolicy
                )
            },
            autosaveEnabled: autosaveEnabled
        ) {
        case .terminate, .prepareAndTerminate:
            prepareAllWindows(states)
            // A failed silent save leaves the document dirty: ask instead of
            // losing the changes.
            return states.contains(where: \.needsUnsavedFileChangesAlert)
                ? askToTerminate()
                : persistSessionAndTerminate()
        case .askUser:
            return askToTerminate()
        }
    }

    /// Saves autosave-covered dirty files silently and stashes every dirty
    /// untitled document's hot-exit backup (and drops backups emptied since
    /// they were stashed). None of this ever prompts.
    private func prepareAllWindows(_ states: [AppState]) {
        for state in states {
            state.prepareForTermination()
        }
    }

    /// Writes the session (hot-exit backup IDs included) and quits. The
    /// windows themselves never "close" on terminate, so nothing else
    /// persists after this.
    private func persistSessionAndTerminate() -> NSApplication.TerminateReply {
        WindowRegistry.shared.persistSession(
            defaults: WindowRegistry.shared.registeredAppStates.first?.userDefaults ?? .standard
        )
        return .terminateNow
    }

    /// Presents the save alerts after returning `.terminateLater`.
    private func askToTerminate() -> NSApplication.TerminateReply {
        DispatchQueue.main.async { [weak self] in
            self?.confirmTermination(bypassed: [])
        }
        return .terminateLater
    }

    /// Alerts one dirty window at a time (Save / Don't Save / Cancel), then
    /// re-runs for the remaining ones. `bypassed` tracks windows the user
    /// already answered "Don't Save" for, so the loop always advances.
    /// Only dirty files without autosave coverage alert: autosave-covered
    /// files save silently and untitled documents stash their hot-exit
    /// backup in the pre-pass. Save runs the full save flow; a cancelled
    /// save leaves the document dirty and aborts the quit.
    private func confirmTermination(bypassed: Set<ObjectIdentifier>) {
        let records = WindowRegistry.shared.records
        for record in records where !bypassed.contains(ObjectIdentifier(record.appState)) {
            record.appState.prepareForTermination()
        }
        guard let next = records.first(where: {
            $0.appState.needsUnsavedFileChangesAlert && !bypassed.contains(ObjectIdentifier($0.appState))
        }) else {
            WindowRegistry.shared.persistSession(
                defaults: records.first?.appState.userDefaults ?? .standard
            )
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        // Surface the window the alert is about.
        next.window?.makeKeyAndOrderFront(nil)
        let document = next.appState.document
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(document.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            next.appState.saveDocument()
            if next.appState.needsUnsavedFileChangesAlert {
                NSApp.reply(toApplicationShouldTerminate: false)
            } else {
                confirmTermination(bypassed: bypassed)
            }
        case .alertSecondButtonReturn:
            confirmTermination(bypassed: bypassed.union([ObjectIdentifier(next.appState)]))
        default:
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }
}
