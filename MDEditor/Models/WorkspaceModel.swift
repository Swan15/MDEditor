import Foundation
import Observation

/// Coordinates the workspace file tree and its file-system watcher.
///
/// Lazy loading: the root level scans on open; a folder scans on first
/// expand. The watcher rescans a directory when it changes on disk and the
/// tree reconciles in place — surviving entries keep their node objects, so
/// expansion state and SwiftUI identity live through refreshes.
@MainActor @Observable
final class WorkspaceModel {
    /// Workspace root; nil means single-file mode.
    private(set) var root: URL?

    /// Top-level visible entries.
    private(set) var nodes: [FileTreeNode] = []

    /// Folders currently expanded in the sidebar.
    private(set) var expandedURLs: Set<URL> = []

    /// True while a rescan runs.
    private(set) var isRescanning = false

    /// Bumped on every structural change, so views re-render even when a
    /// deep mutation escapes Observation tracking.
    private(set) var revision = 0

    /// Last URL asked to be revealed (the sidebar scrolls to it).
    private(set) var lastRevealedURL: URL?

    /// Directory watcher; nil in tests that drive rescans manually.
    private let watcher: FileSystemWatcher?

    /// Every loaded node by URL (reveal + rescan lookups).
    private var nodesByURL: [URL: FileTreeNode] = [:]

    init(debounceInterval: Duration = .milliseconds(300), watchingEnabled: Bool = true) {
        watcher = watchingEnabled ? FileSystemWatcher(debounceInterval: debounceInterval) : nil
        watcher?.onChange = { [weak self] directories in
            self?.handleChanged(directories: directories)
        }
    }

    /// Opens a folder as the workspace root and starts watching it.
    func openWorkspace(at url: URL) {
        watcher?.stopWatchingAll()
        let root = url.standardizedFileURL
        self.root = root
        expandedURLs = []
        lastRevealedURL = nil
        nodesByURL = [:]
        nodes = []
        let topLevel = FileTreeModel.scanChildren(of: root)
        register(topLevel)
        nodes = topLevel
        watcher?.watch(directory: root)
        revision += 1
    }

    /// Closes the workspace, back to single-file mode.
    func closeWorkspace() {
        watcher?.stopWatchingAll()
        root = nil
        nodes = []
        nodesByURL = [:]
        expandedURLs = []
        lastRevealedURL = nil
        revision += 1
    }

    /// Expansion toggle from the sidebar; loads children on first expand and
    /// puts a watcher on the folder.
    func setExpanded(_ node: FileTreeNode, _ expanded: Bool) {
        if expanded {
            expandedURLs.insert(node.url)
            ensureLoaded(node)
            watcher?.watch(directory: node.url)
        } else {
            expandedURLs.remove(node.url)
        }
    }

    /// Loads a folder's children if it was never expanded.
    func ensureLoaded(_ node: FileTreeNode) {
        guard node.isFolder, node.children == nil else { return }
        let children = FileTreeModel.scanChildren(of: node.url)
        register(children)
        node.children = children
        revision += 1
    }

    /// Rescans a directory in place: new entries appear, vanished entries
    /// drop out, surviving entries keep their node objects.
    func rescan(directory: URL) {
        let directory = directory.standardizedFileURL
        let fresh = FileTreeModel.scanChildren(of: directory)
        isRescanning = true
        defer { isRescanning = false }
        if directory == root {
            nodes = reconcile(existing: nodes, fresh: fresh)
        } else if let node = nodesByURL[directory], let existing = node.children {
            node.children = reconcile(existing: existing, fresh: fresh)
        }
        revision += 1
    }

    /// Expands every ancestor of `url` (when inside the workspace) so the
    /// sidebar shows it, and records it for scrolling. No-op outside the root.
    func reveal(_ url: URL) {
        guard let root else { return }
        let url = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath), url.path != root.path else { return }
        // Ancestor chain between root (excluded) and the file's parent.
        var ancestors: [URL] = []
        var current = url.deletingLastPathComponent()
        while current.path != root.path {
            ancestors.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return }
            current = parent
        }
        // Walk root-down, expanding (which loads) each level.
        var level = nodes
        for directory in ancestors.reversed() {
            guard let node = level.first(where: { $0.url == directory }) else { return }
            setExpanded(node, true)
            level = node.children ?? []
        }
        lastRevealedURL = url
    }

    // MARK: - Private

    /// Watcher callback: rescan changed directories, parents first so a
    /// vanished folder is dropped before its own (now unreadable) rescan.
    private func handleChanged(directories: Set<URL>) {
        for directory in directories.sorted(by: { $0.path.count < $1.path.count }) {
            rescan(directory: directory)
        }
        let pruned = expandedURLs.filter { nodesByURL[$0] != nil }
        if pruned != expandedURLs {
            expandedURLs = pruned
        }
    }

    /// Merges a fresh scan with the existing children, keeping node identity
    /// for survivors and unregistering vanished subtrees.
    private func reconcile(existing: [FileTreeNode], fresh: [FileTreeNode]) -> [FileTreeNode] {
        let existingByURL = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FileTreeNode] = []
        for node in fresh {
            if let kept = existingByURL[node.url] {
                result.append(kept)
            } else {
                register([node])
                result.append(node)
            }
        }
        let keptURLs = Set(result.map(\.url))
        unregister(existing.filter { !keptURLs.contains($0.url) })
        return result
    }

    private func register(_ newNodes: [FileTreeNode]) {
        for node in newNodes {
            nodesByURL[node.url] = node
        }
    }

    private func unregister(_ stale: [FileTreeNode]) {
        for node in stale {
            nodesByURL.removeValue(forKey: node.url)
            unregister(node.children ?? [])
        }
    }
}
