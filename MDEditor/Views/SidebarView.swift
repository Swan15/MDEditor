import SwiftUI

/// Folder-mode sidebar: a VSCode-style welcome state without a workspace,
/// and the workspace file tree (folders + Markdown files) with one open.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.workspaceRoot != nil {
                WorkspaceSidebarView()
            } else {
                WelcomeSidebarView()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }
}

/// No-workspace state: the two ways in, VSCode-welcome style.
private struct WelcomeSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No Folder Opened")
                .font(.headline)
            Text("Open a folder to browse your Markdown files, or work with a single document.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Folder…") { appState.requestOpenFolder() }
            Button("Open File…") { appState.requestOpenDocument() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

/// The workspace tree: root header (name + close) above the file list.
private struct WorkspaceSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List {
                    // Reading `revision` forces a rebuild on deep tree changes.
                    let _ = appState.workspace.revision
                    if appState.workspace.nodes.isEmpty {
                        Text("No Markdown files")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.workspace.nodes) { node in
                            SidebarNodeRow(node: node)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: appState.workspace.lastRevealedURL) { _, url in
                    guard let url else { return }
                    // Expansion lands first; scroll once rows exist.
                    DispatchQueue.main.async {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
            }
        }
    }

    /// Root name + the close-workspace affordance (back to single-file mode).
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(appState.workspaceRoot?.lastPathComponent ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                appState.closeWorkspace()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close Folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One tree row. Folders are disclosure groups that load lazily on expand;
/// files open on click and highlight while they're the current document.
private struct SidebarNodeRow: View {
    @Environment(AppState.self) private var appState
    let node: FileTreeNode

    /// True while this file is the one open in the editor.
    private var isCurrentFile: Bool {
        appState.document.fileURL == node.url
    }

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    SidebarNodeRow(node: child)
                }
            } label: {
                rowLabel(icon: "folder", tint: .accentColor)
            }
            .contextMenu { contextMenuItems }
        } else {
            Button {
                appState.requestOpenDocument(at: node.url)
            } label: {
                rowLabel(icon: "doc.text", tint: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isCurrentFile ? Color.accentColor.opacity(0.2) : Color.clear)
            .contextMenu { contextMenuItems }
        }
    }

    /// Expansion lives in the model so reveals and rescans can drive it.
    private var expansion: Binding<Bool> {
        Binding(
            get: { appState.workspace.expandedURLs.contains(node.url) },
            set: { appState.workspace.setExpanded(node, $0) }
        )
    }

    private func rowLabel(icon: String, tint: Color) -> some View {
        Label {
            Text(node.name)
                .foregroundStyle(isCurrentFile ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("New File") { appState.sidebarNewFile(in: targetFolder) }
        Button("New Folder") { appState.sidebarNewFolder(in: targetFolder) }
        Divider()
        Button("Rename…") { appState.sidebarRename(node) }
        Button("Move to Trash") { appState.sidebarDelete(node) }
        Divider()
        Button("Reveal in Finder") { appState.sidebarReveal(node) }
    }

    /// Folder ops on a file row target the file's containing folder.
    private var targetFolder: URL {
        node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }
}
