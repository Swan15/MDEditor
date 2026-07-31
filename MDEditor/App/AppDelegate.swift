import AppKit

/// Application delegate: quit-time dirty-document protection across every
/// open window.
///
/// Quitting checks all registered windows: clean sessions (or none) quit
/// directly; autosave-covered dirty documents save silently; anything else
/// gets a Save / Don't Save / Cancel alert per window, delivered
/// asynchronously via `.terminateLater` + `reply(toApplicationShouldTerminate:)`.
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
                    isDirty: $0.document.isDirty,
                    hasFileURL: $0.document.fileURL != nil
                )
            },
            autosaveEnabled: autosaveEnabled
        ) {
        case .terminate:
            return .terminateNow
        case .saveSilentlyAndTerminate:
            for state in states where state.document.isDirty {
                state.saveDocumentSilently()
            }
            // A failed silent save leaves the document dirty: ask instead of
            // losing the changes.
            return states.contains(where: { $0.document.isDirty }) ? askToTerminate() : .terminateNow
        case .askUser:
            return askToTerminate()
        }
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
    /// Save runs the full save flow (including the location panel); a
    /// cancelled save leaves the document dirty and aborts the quit.
    private func confirmTermination(bypassed: Set<ObjectIdentifier>) {
        let records = WindowRegistry.shared.records
        let autosaveEnabled = settings?.autosaveEnabled ?? true
        // Autosave-covered documents save silently without asking.
        for record in records {
            let document = record.appState.document
            let id = ObjectIdentifier(record.appState)
            if document.isDirty, autosaveEnabled, document.fileURL != nil, !bypassed.contains(id) {
                record.appState.saveDocumentSilently()
            }
        }
        guard let next = records.first(where: {
            $0.appState.document.isDirty && !bypassed.contains(ObjectIdentifier($0.appState))
        }) else {
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
            if next.appState.document.isDirty {
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
