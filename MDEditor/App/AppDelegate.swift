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

    /// Installs our own Apple Event handler for 'odoc' (Finder double-click,
    /// Dock drop, `open`): SwiftUI's WindowGroup installs a handler that
    /// swallows the event without forwarding it to the app delegate or
    /// `onOpenURL`, so files would never reach us otherwise. Installed at
    /// will- AND did-finish-launching so ours wins regardless of when
    /// SwiftUI registers its own.
    func applicationWillFinishLaunching(_ notification: Notification) {
        installOpenDocumentsHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installOpenDocumentsHandler()
    }

    private func installOpenDocumentsHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// Routes every opened document through the registry (already-open files
    /// focus their window; the rest open in the key window or their own).
    @objc private func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        for index in 1...list.numberOfItems {
            guard let item = list.atIndex(index) else { continue }
            // LaunchServices sends security-scoped bookmarks ('bmrk') to
            // sandboxed apps; Finder/drop sends may use file URLs or aliases.
            if item.descriptorType == typeBookmarkData, let url = Self.resolveOpenBookmark(item.data) {
                urls.append(url)
                continue
            }
            let descriptor = item.coerce(toDescriptorType: typeFileURL) ?? item
            guard let string = descriptor.stringValue, let url = URL(string: string) else { continue }
            urls.append(url)
        }
        WindowRegistry.shared.openFiles(urls)
        // A document-triggered launch can create NO window (the launch "had
        // documents"), leaving queued files with nothing to drain into.
        // Give SwiftUI a moment to create its own window; if none appeared,
        // sending ourselves a reopen is the Dock-click path that forces one
        // (it drains the queue on appear).
        if !urls.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard WindowRegistry.shared.records.isEmpty else { return }
                let reopen = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kCoreEventClass),
                    eventID: AEEventID(kAEReopenApplication),
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                    returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: 0
                )
                try? reopen.sendEvent(options: .noReply, timeout: 2)
            }
        }
    }

    /// Resolves a bookmark from an 'odoc' event. LS event bookmarks don't
    /// always resolve as security-scoped, so plain resolution is the
    /// fallback; the event's own sandbox extension grants file access.
    private static func resolveOpenBookmark(_ data: Data) -> URL? {
        var isStale = false
        for options: URL.BookmarkResolutionOptions in [[.withSecurityScope], []] {
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return nil
    }

    /// Fallback path (the registry dedupes if both fire); the Apple Event
    /// handler above owns the event in practice.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        WindowRegistry.shared.openFiles(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.reply(toOpenOrPrint: .success)
    }

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
