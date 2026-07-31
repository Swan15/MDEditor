import Foundation
import Observation

/// One entry in the workspace file tree: a folder or a Markdown file.
///
/// `children` stays nil until the folder is first expanded (lazy loading
/// keeps large folders cheap); once loaded it holds the folder's visible
/// entries. Nodes are observable so the sidebar re-renders on rescans.
@Observable
final class FileTreeNode: Identifiable {
    /// Location on disk (standardized).
    let url: URL

    /// Display name (last path component).
    let name: String

    /// True for folders, false for Markdown files.
    let isFolder: Bool

    /// Visible children; nil while the folder was never expanded.
    var children: [FileTreeNode]?

    var id: URL { url }

    init(url: URL, name: String, isFolder: Bool, children: [FileTreeNode]? = nil) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.children = children
    }
}

/// Builds the workspace tree one directory level at a time: folders and
/// Markdown files only, dotfiles hidden, sorted VSCode-style (folders
/// first, then files, localized case-insensitive).
enum FileTreeModel {
    /// File extensions shown in the tree (lowercase).
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// True for `.md` / `.markdown` files (any case).
    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Scans a single directory level (never recurses). Returns folders and
    /// Markdown files, folders first; everything else and dotfiles are hidden.
    /// A missing/unreadable directory scans as empty.
    static func scanChildren(of directory: URL, fileManager: FileManager = .default) -> [FileTreeNode] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let node = FileTreeNode(url: url.standardizedFileURL, name: name, isFolder: isDirectory)
            if isDirectory {
                folders.append(node)
            } else if isMarkdownFile(url) {
                files.append(node)
            }
        }
        let byName: (FileTreeNode, FileTreeNode) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }
}

/// On-disk mutations behind the sidebar's context menu. All operations
/// throw on failure (callers alert); delete always goes through the Trash.
enum FileTreeOperations {
    /// Errors raised before touching disk.
    enum OperationError: LocalizedError, Equatable {
        /// The rename target name is already taken in the same folder.
        case nameAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .nameAlreadyExists(let name):
                return "An item named “\(name)” already exists in this folder."
            }
        }
    }

    /// Creates an empty Markdown file ("untitled.md", deduped) in `directory`.
    @discardableResult
    static func createMarkdownFile(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = dedupedURL(in: directory, baseName: "untitled", pathExtension: "md", separator: "-", fileManager: fileManager)
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Creates a folder ("untitled folder", deduped) in `directory`.
    @discardableResult
    static func createFolder(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = dedupedURL(in: directory, baseName: "untitled folder", pathExtension: nil, separator: " ", fileManager: fileManager)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames `url` to `newName` within the same folder and returns the new
    /// URL. Throws `.nameAlreadyExists` on a collision (never overwrites).
    @discardableResult
    static func rename(at url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OperationError.nameAlreadyExists(newName)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves the item to the Trash (never unlinks).
    static func moveToTrash(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    /// First non-existing candidate: "base.ext", then "base-2.ext", "base-3.ext"
    /// … (separator " " for folders, Finder-style).
    static func dedupedURL(
        in directory: URL,
        baseName: String,
        pathExtension: String?,
        separator: String,
        fileManager: FileManager = .default
    ) -> URL {
        func candidate(_ counter: Int?) -> URL {
            let name = counter.map { "\(baseName)\(separator)\($0)" } ?? baseName
            if let pathExtension {
                return directory.appendingPathComponent("\(name).\(pathExtension)")
            }
            return directory.appendingPathComponent(name)
        }
        var counter: Int?
        var url = candidate(nil)
        while fileManager.fileExists(atPath: url.path) {
            counter = (counter ?? 1) + 1
            url = candidate(counter)
        }
        return url
    }
}
