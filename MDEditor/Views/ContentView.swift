import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var formatBus = FormatCommandBus.shared

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if appState.hasDocument {
                VStack(spacing: 0) {
                    MarkdownTextView(appState: appState)
                    Divider()
                    StatusBarView(document: appState.document)
                }
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(appState.workspaceRoot?.lastPathComponent ?? "")
        .toolbar { toolbarContent }
        .onChange(of: appState.document.fileURL, initial: true) { _, newURL in
            // Reveal files opened via ⌘O / recents / Save As in the sidebar.
            if let newURL {
                appState.workspace.reveal(newURL)
            }
        }
        .onChange(of: appState.hasDocument) { _, _ in
            // The editor just (un)mounted without a focus change: re-assert
            // the format-bus target (nil in the empty state).
            WindowRegistry.shared.retargetIfMain(appState: appState)
        }
    }

    /// Document title (with dirty marker), or the app name in the empty state.
    private var windowTitle: String {
        guard appState.hasDocument else { return "MDEditor" }
        return appState.document.isDirty ? "\(appState.document.title) •" : appState.document.title
    }

    /// The formatting cluster only exists with a document open.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if appState.hasDocument {
            formattingToolbar
        }
    }

    /// Minimal formatting cluster reflecting the state at the selection.
    @ToolbarContentBuilder
    private var formattingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let state = formatBus.selection
            Button { formatBus.send(.toggleBold) } label: { Image(systemName: "bold") }
                .foregroundStyle(state.isBold ? Color.accentColor : Color.primary)
                .help("Bold (⌘B)")
            Button { formatBus.send(.toggleItalic) } label: { Image(systemName: "italic") }
                .foregroundStyle(state.isItalic ? Color.accentColor : Color.primary)
                .help("Italic (⌘I)")
            Button { formatBus.send(.toggleStrikethrough) } label: { Image(systemName: "strikethrough") }
                .foregroundStyle(state.isStrikethrough ? Color.accentColor : Color.primary)
                .help("Strikethrough (⇧⌘X)")
            headingMenu(state: state)
            Button { formatBus.send(.toggleOrderedList) } label: { Image(systemName: "list.number") }
                .foregroundStyle(state.isOrderedList ? Color.accentColor : Color.primary)
                .help("Ordered List (⇧⌘7)")
            Button { formatBus.send(.toggleBulletList) } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(state.isBulletList ? Color.accentColor : Color.primary)
                .help("Bullet List (⇧⌘8)")
            Button { formatBus.send(.toggleBlockQuote) } label: { Image(systemName: "text.quote") }
                .foregroundStyle(state.isBlockQuote ? Color.accentColor : Color.primary)
                .help("Block Quote (⇧⌘.)")
            Button { formatBus.send(.toggleCodeBlock) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                .foregroundStyle(state.isCodeBlock ? Color.accentColor : Color.primary)
                .help("Code Block (⇧⌘C)")
            Button { formatBus.send(.insertLink) } label: { Image(systemName: "link") }
                .help("Insert Link (⌘K)")
            Button { formatBus.send(.insertThematicBreak) } label: { Image(systemName: "minus") }
                .help("Horizontal Rule (⇧⌘H)")
            Button { formatBus.send(.insertTable) } label: { Image(systemName: "tablecells") }
                .help("Insert Table (⌥⌘T)")
            tableMenu(state: state)
        }
    }

    /// Table structure commands (enabled only while the caret is in a table).
    private func tableMenu(state: SelectionFormatState) -> some View {
        Menu {
            Button("Insert Row Above") { formatBus.send(.insertRowAbove) }
            Button("Insert Row Below") { formatBus.send(.insertRowBelow) }
            Button("Delete Row") { formatBus.send(.deleteRow) }
            Divider()
            Button("Insert Column Left") { formatBus.send(.insertColumnLeft) }
            Button("Insert Column Right") { formatBus.send(.insertColumnRight) }
            Button("Delete Column") { formatBus.send(.deleteColumn) }
            Divider()
            Button("Cycle Column Alignment") { formatBus.send(.cycleColumnAlignment) }
        } label: {
            Image(systemName: "tablecells.badge.ellipsis")
                .foregroundStyle(state.isInTable ? Color.accentColor : Color.secondary)
        }
        .disabled(!state.isInTable)
        .help("Table")
    }

    /// Paragraph-style picker (body + headings 1–6).
    private func headingMenu(state: SelectionFormatState) -> some View {
        Menu {
            Button("Body Text") { formatBus.send(.body) }
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { formatBus.send(.heading(level)) }
            }
        } label: {
            Image(systemName: "textformat.size")
                .foregroundStyle(state.headingLevel != nil ? Color.accentColor : Color.primary)
        }
        .help("Paragraph Style")
    }
}
