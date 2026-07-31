import AppKit
import SwiftUI

@main
struct MDEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Preferences shared by every window and the Settings scene.
    @State private var settings = AppSettings()
    @State private var formatBus = FormatCommandBus.shared
    @State private var registry = WindowRegistry.shared

    /// Minimum window size: phone-width and tall enough that the sidebar,
    /// editor and status bar all stay usable.
    static let minimumWindowSize = NSSize(width: 480, height: 560)

    var body: some Scene {
        // Each window gets its own AppState (document, workspace, autosave);
        // the session value carries per-window restore data (the launch
        // window opens with the empty default and picks up the persisted
        // session, opening the other restored windows itself).
        WindowGroup(for: WindowSession.self) { $session in
            WindowRootView(session: session, settings: settings)
                .onAppear {
                    appDelegate.settings = settings
                    // Wire the shared preferences into the update checker and
                    // fire the once-per-launch automatic check (the checker
                    // guards it, so extra windows don't re-fire).
                    UpdateChecker.shared.settings = settings
                    UpdateChecker.shared.scheduleAutomaticCheckIfNeeded()
                }
        } defaultValue: {
            WindowSession()
        }
        .defaultSize(width: 1100, height: 750)
        .windowResizability(.contentMinSize)
        .commands {
            appCommands
            fileCommands
            pasteCommands
            insertCommands
            formatCommands
        }

        Settings {
            SettingsView(settings: settings)
        }
    }

    /// "Check for Updates…" in the application menu, above Settings… (the
    /// standard spot). A manual check always runs and reports the outcome.
    private var appCommands: some Commands {
        CommandGroup(before: .appSettings) {
            Button("Check for Updates…") {
                Task { await UpdateChecker.shared.checkForUpdates(manual: true) }
            }
            Divider()
        }
    }

    /// File operations on the main window's document and workspace
    /// (disabled with no window open; New Window always works). Everything
    /// that swaps documents routes through the dirty-switching rules.
    private var fileCommands: some Commands {
        Group {
            CommandGroup(replacing: .newItem) {
                Button("New") { registry.mainAppState?.requestNewDocument() }
                    .keyboardShortcut("n")
                    .disabled(registry.mainAppState == nil)
                Button("New Window") { registry.openWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                Button("Open…") { registry.mainAppState?.requestOpenDocument() }
                    .keyboardShortcut("o")
                    .disabled(registry.mainAppState == nil)
                openRecentMenu
                Button("Open Folder…") { registry.mainAppState?.requestOpenFolder() }
                    .disabled(registry.mainAppState == nil)
                Divider()
                Button("Close Document") { registry.mainAppState?.closeDocument() }
                    .keyboardShortcut("w")
                    .disabled(registry.mainAppState == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { registry.mainAppState?.saveDocument() }
                    .keyboardShortcut("s")
                    .disabled(registry.mainAppState == nil)
                Button("Save As…") { registry.mainAppState?.saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(registry.mainAppState == nil)
                Divider()
                Button("Export as PDF…") { registry.mainAppState?.exportPDF() }
                    .disabled(registry.mainAppState == nil)
                Button("Print…") { registry.mainAppState?.printDocument() }
                    .keyboardShortcut("p")
                    .disabled(registry.mainAppState == nil)
            }
        }
    }

    /// File ▸ Open Recent, fed by NSDocumentController (updated on open/save).
    private var openRecentMenu: some View {
        Menu("Open Recent") {
            let recents = NSDocumentController.shared.recentDocumentURLs
            ForEach(recents.prefix(10), id: \.self) { url in
                Button(url.lastPathComponent) { registry.mainAppState?.requestOpenDocument(at: url) }
            }
            if !recents.isEmpty {
                Divider()
                Button("Clear Menu") {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                }
            }
        }
        .disabled(registry.mainAppState == nil)
    }

    /// Paste variant that always inserts the raw text, bypassing the
    /// Markdown paste conversion (handled by the standard responder-chain action).
    private var pasteCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Paste as Plain Text") {
                NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
        }
    }

    /// Insert menu. ⇧⌘I for Image: ⌘I is Italic, and ⇧⌘I is unused both in
    /// the app and by macOS globally.
    private var insertCommands: some Commands {
        CommandMenu("Insert") {
            Button("Image…") { formatBus.send(.insertImage) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!formatBus.hasTarget)
        }
    }

    /// Word-like format menu; commands route to the main window's editor via
    /// the bus (all disabled when no window is open).
    /// Note: ⇧⌘Q is reserved by macOS (Log Out), so Block Quote uses ⇧⌘.
    /// (the shifted "." is ">", the quote marker).
    private var formatCommands: some Commands {
        CommandMenu("Format") {
            let bus = formatBus
            Button("Bold") { bus.send(.toggleBold) }
                .keyboardShortcut("b")
                .disabled(!bus.hasTarget)
            Button("Italic") { bus.send(.toggleItalic) }
                .keyboardShortcut("i")
                .disabled(!bus.hasTarget)
            Button("Strikethrough") { bus.send(.toggleStrikethrough) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Divider()
            Button("Body Text") { bus.send(.body) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { bus.send(.heading(level)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .shift])
                    .disabled(!bus.hasTarget)
            }
            Divider()
            Button("Ordered List") { bus.send(.toggleOrderedList) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Button("Bullet List") { bus.send(.toggleBulletList) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Button("Block Quote") { bus.send(.toggleBlockQuote) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Button("Code Block") { bus.send(.toggleCodeBlock) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Divider()
            Button("Insert Link…") { bus.send(.insertLink) }
                .keyboardShortcut("k")
                .disabled(!bus.hasTarget)
            Button("Horizontal Rule") { bus.send(.insertThematicBreak) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!bus.hasTarget)
            Divider()
            Button("Insert Table") { bus.send(.insertTable) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!bus.hasTarget)
            Button("Insert Row Above") { bus.send(.insertRowAbove) }
                .disabled(!bus.selection.isInTable)
            Button("Insert Row Below") { bus.send(.insertRowBelow) }
                .disabled(!bus.selection.isInTable)
            Button("Delete Row") { bus.send(.deleteRow) }
                .disabled(!bus.selection.isInTable)
            Button("Insert Column Left") { bus.send(.insertColumnLeft) }
                .disabled(!bus.selection.isInTable)
            Button("Insert Column Right") { bus.send(.insertColumnRight) }
                .disabled(!bus.selection.isInTable)
            Button("Delete Column") { bus.send(.deleteColumn) }
                .disabled(!bus.selection.isInTable)
            Button("Cycle Column Alignment") { bus.send(.cycleColumnAlignment) }
                .disabled(!bus.selection.isInTable)
        }
    }
}
