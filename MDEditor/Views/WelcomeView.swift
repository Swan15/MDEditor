import AppKit
import SwiftUI

/// The empty state (no document open): a quiet VSCode-style welcome with
/// the app identity, the two ways in (New / Open) and the recent files.
/// Shown in the detail area in place of the editor; the formatting toolbar
/// and status bar hide alongside it.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    /// Recent files, same source as File ▸ Open Recent (capped like
    /// VSCode's welcome list).
    private var recents: [URL] {
        Array(NSDocumentController.shared.recentDocumentURLs.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("MDEditor")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 10) {
                actionRow(title: "New Document", shortcut: "⌘N") {
                    appState.requestNewDocument()
                }
                actionRow(title: "Open…", shortcut: "⌘O") {
                    appState.requestOpenDocument()
                }
            }
            .padding(.top, 28)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    ForEach(recents, id: \.self) { url in
                        Button {
                            appState.requestOpenDocument(at: url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 280, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 32)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One welcome action row: title left, keyboard shortcut hint right.
    private func actionRow(title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 280)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.title3)
    }
}
