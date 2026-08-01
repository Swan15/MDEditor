import SwiftUI

/// One editor window: owns its `AppState` (document, workspace, autosave),
/// registers its `NSWindow` with the `WindowRegistry` (main-window command
/// routing + close interception) and restores its persisted session.
struct WindowRootView: View {
    @Environment(\.openWindow) private var openWindow

    /// This window's state. `@State` keeps one instance per window across
    /// view re-creations.
    @State private var appState: AppState

    init(session: WindowSession?, settings: AppSettings) {
        // An empty session value (the default) carries no restore data — the
        // launch window picks up the persisted session in `onAppear` instead.
        let restore = session?.hasContent == true ? session : nil
        _appState = State(initialValue: AppState(settings: settings, restore: restore))
    }

    var body: some View {
        ContentView()
            .environment(appState)
            .frame(
                minWidth: MDEditorApp.minimumWindowSize.width,
                minHeight: MDEditorApp.minimumWindowSize.height
            )
            .background(WindowConfigurator { window in
                WindowRegistry.shared.attach(window: window, appState: appState)
            })
            .onAppear {
                let registry = WindowRegistry.shared
                // Bridge `openWindow` for menu commands (the environment
                // value isn't reachable from `.commands`).
                registry.openWindowHandler = { openWindow(value: $0) }
                registry.restoreSessionOnLaunch(appState: appState) { openWindow(value: $0) }
                appState.restoreSessionIfNeeded()
                // Files double-clicked in Finder before this window existed
                // open now, deduped against the restored session.
                registry.drainPendingOpenURLs(preferredAppState: appState)
            }
    }
}

/// Reports the hosting `NSWindow` once the view is inside one (SwiftUI has
/// no public window accessor).
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowChange = { window in
            if let window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}
}

private final class WindowObserverView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
