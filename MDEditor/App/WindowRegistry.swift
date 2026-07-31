import AppKit

/// Tracks every open editor window and routes global commands (menus,
/// toolbar) to the main window's state.
///
/// Each window registers on appear (`attach`) with its per-window `AppState`;
/// the registry installs a `WindowCloseController` as the window delegate,
/// which reports main-window changes and the close lifecycle back. The most
/// recently main window is `mainRecord` — File-menu actions target its
/// `mainAppState`, and the format bus targets its editor.
@MainActor @Observable
final class WindowRegistry {
    /// Shared registry (main-actor isolated, like everything that touches it).
    static let shared = WindowRegistry()

    /// One registered editor window and its per-window objects.
    final class WindowRecord {
        weak var window: NSWindow?
        let appState: AppState
        let closeController: WindowCloseController

        init(window: NSWindow, appState: AppState, closeController: WindowCloseController) {
            self.window = window
            self.appState = appState
            self.closeController = closeController
        }
    }

    /// Registered windows, most-recently-main first (≈ z-order; the session
    /// restores in this order).
    private(set) var records: [WindowRecord] = []

    /// The window all global commands target; nil when no window is open.
    private(set) var mainRecord: WindowRecord?

    /// The bus to retarget on focus changes (injectable for tests).
    private let bus: FormatCommandBus

    /// The most recent window's `openWindow` action, bridged from the SwiftUI
    /// environment so menu commands (which can't reach it) can open windows.
    var openWindowHandler: ((WindowSession) -> Void)?

    /// Guards the one-shot launch restore fan-out.
    private var didRestoreOnLaunch = false

    init(bus: FormatCommandBus = .shared) {
        self.bus = bus
    }

    /// The main window's state (menu commands target this).
    var mainAppState: AppState? { mainRecord?.appState }

    /// Every open window's state, most-recently-main first.
    var registeredAppStates: [AppState] { records.map(\.appState) }

    /// Opens a new window presenting `session` (a fresh one by default).
    func openWindow(with session: WindowSession = WindowSession()) {
        openWindowHandler?(session)
    }

    /// Registers a window with its state and installs the close interceptor.
    /// Idempotent per window (the SwiftUI window accessor can fire twice).
    func attach(window: NSWindow, appState: AppState) {
        guard !records.contains(where: { $0.window === window }) else { return }
        let controller = WindowCloseController(window: window, appState: appState, registry: self)
        records.append(WindowRecord(window: window, appState: appState, closeController: controller))
        if window.isMainWindow { noteBecameMain(window: window) }
        // A window restored before its attach persisted nothing (its state
        // wasn't registered); join it to the stored session now.
        if didRestoreOnLaunch, appState.didRestoreSession {
            persist(defaults: appState.userDefaults)
        }
    }

    /// Moves the window to the front (≈ z-order) and retargets global
    /// commands at it. Called when the window becomes main (notification
    /// reported by the close controller, or at attach when already main).
    func noteBecameMain(window: NSWindow) {
        guard let record = records.first(where: { $0.window === window }) else { return }
        records.removeAll { $0 === record }
        records.insert(record, at: 0)
        mainRecord = record
        retarget(to: record)
    }

    /// Drops the window and re-persists the session without it. When the
    /// main window goes away, commands retarget the next one in z-order.
    func unregister(window: NSWindow) {
        guard let index = records.firstIndex(where: { $0.window === window }) else { return }
        let record = records.remove(at: index)
        if mainRecord === record {
            mainRecord = records.first
            if let mainRecord {
                retarget(to: mainRecord)
            } else {
                bus.target = nil
                bus.selection = SelectionFormatState()
            }
        }
        persist(defaults: record.appState.userDefaults)
    }

    /// One-shot launch restore: hands the first persisted window session to
    /// the launch window's state and opens one window per remaining entry.
    func restoreSessionOnLaunch(appState: AppState, openWindow: (WindowSession) -> Void) {
        guard !didRestoreOnLaunch else { return }
        didRestoreOnLaunch = true
        let entries = SessionRestore.restoreWindowEntries(defaults: appState.userDefaults)
        guard let first = entries.first else { return }
        appState.pendingRestore = first
        for entry in entries.dropFirst() {
            openWindow(entry)
        }
    }

    /// Writes the session for every registered window, most-recently-main first.
    private func persist(defaults: UserDefaults) {
        SessionRestore.persist(
            windows: records.map { WindowSession(fileURL: $0.appState.document.fileURL, workspaceRoot: $0.appState.workspaceRoot) },
            defaults: defaults
        )
    }

    /// Points the format bus at the record's editor and refreshes the
    /// published selection state (menus/toolbar reflect the main window).
    private func retarget(to record: WindowRecord) {
        let target = record.appState.formatTarget
        bus.target = target
        target?.publishSelectionState()
    }
}

/// Per-window delegate: intercepts the close button to run the dirty-document
/// policy, and reports main-window changes and teardown to the registry.
///
/// SwiftUI installs its own delegate on `WindowGroup` windows (its window
/// controller), so this installs as a forwarding proxy: only
/// `windowShouldClose` is handled here (it needs the delegate for the veto);
/// every other message forwards to SwiftUI's delegate, and main-window /
/// close tracking uses `NotificationCenter` so nothing is shadowed.
@MainActor
final class WindowCloseController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private let appState: AppState
    private let registry: WindowRegistry

    /// SwiftUI's own window delegate, kept so every message this controller
    /// doesn't handle still reaches it. Accessed from the nonisolated
    /// `responds(to:)` / `forwardingTarget(for:)` overrides.
    nonisolated(unsafe) private weak var originalDelegate: NSWindowDelegate?

    /// One-shot bypass after the user already confirmed the close (Don't
    /// Save): the re-sent `windowShouldClose` must not re-ask.
    private var allowClose = false

    init(window: NSWindow, appState: AppState, registry: WindowRegistry) {
        self.window = window
        self.appState = appState
        self.registry = registry
        self.originalDelegate = window.delegate
        super.init()
        window.delegate = self
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeMainNotification(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowWillCloseNotification(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Forwarding to SwiftUI's delegate

    /// NSWindow checks `responds(to:)` before messaging its delegate, so
    /// advertising SwiftUI's delegate's methods keeps them delivered.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return originalDelegate?.responds(to: selector) ?? false
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: selector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    // MARK: - Close interception

    /// The red close button: clean windows close directly; autosave-covered
    /// dirty documents save silently first; anything else runs the Save /
    /// Don't Save / Cancel alert asynchronously (`windowShouldClose` must
    /// return synchronously) and closes the window afterwards when allowed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose {
            allowClose = false
            return true
        }
        let document = appState.document
        switch DocumentSwitchPolicy.closeAction(
            isDirty: document.isDirty,
            hasFileURL: document.fileURL != nil,
            autosaveEnabled: appState.settings.autosaveEnabled
        ) {
        case .close:
            return true
        case .saveSilentlyAndClose:
            appState.saveDocumentSilently()
            // A failed silent save leaves the document dirty: ask instead of
            // losing the changes.
            guard document.isDirty else { return true }
            askToClose()
            return false
        case .askUser:
            askToClose()
            return false
        }
    }

    /// Save / Don't Save / Cancel. Save runs the full save flow (including
    /// the location panel for untitled documents); a cancelled save leaves
    /// the document dirty and aborts the close.
    private func askToClose() {
        let document = appState.document
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes to “\(document.title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                self.appState.saveDocument()
                if !document.isDirty { self.closeNow() }
            case .alertSecondButtonReturn:
                self.closeNow()
            default:
                break
            }
        }
    }

    private func closeNow() {
        allowClose = true
        window?.close()
    }

    // MARK: - Registry reporting (notifications, not delegate methods)

    @objc private func windowDidBecomeMainNotification(_ notification: Notification) {
        guard let window else { return }
        registry.noteBecameMain(window: window)
    }

    @objc private func windowWillCloseNotification(_ notification: Notification) {
        guard let window else { return }
        NotificationCenter.default.removeObserver(self)
        window.delegate = nil
        registry.unregister(window: window)
    }
}
