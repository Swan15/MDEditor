import AppKit

/// Stores images on disk next to the document so every markdown image
/// reference stays relative and durable.
///
/// Layout: `<document folder>/assets/<name>.<ext>` — created on demand.
/// png/jpg/jpeg/gif files are copied byte-for-byte (no recompression);
/// anything else (TIFF from screenshots, HEIC, …) is converted to PNG via
/// `NSBitmapImageRep`. Name collisions dedupe as `name-2.png`, `name-3.png`.
///
/// Filenames keep their spaces: the serializer wraps destinations containing
/// spaces in `<…>` (`![alt](<assets/my pic.png>)`), which the parser reads
/// back byte-for-byte, so literal spaces round-trip cleanly. (Percent-encoded
/// sources from foreign files also load — see the controller's fallback.)
enum ImageAssetStore {
    /// Failures of the store pipeline.
    enum StoreError: Error {
        /// The document has never been saved, so there is no folder to put
        /// assets in. The UI requires a save before inserting; this is the
        /// logic seam for that abort path.
        case unsavedDocument
        /// The data couldn't be decoded or re-encoded as PNG.
        case imageConversionFailed
    }

    /// Folder name holding a document's images.
    static let directoryName = "assets"

    /// Extensions copied verbatim; everything else becomes PNG.
    private static let verbatimExtensions: Set<String> = ["png", "jpg", "jpeg", "gif"]

    /// PNG magic bytes — pasted PNG data is written verbatim, not re-encoded.
    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    /// Copies an existing image file into the document's assets folder.
    /// Returns the POSIX path relative to the document plus the file URL.
    @discardableResult
    static func storeImage(
        from sourceURL: URL,
        documentURL: URL?
    ) throws -> (relativePath: String, fileURL: URL) {
        guard let documentURL else { throw StoreError.unsavedDocument }
        let ext = sourceURL.pathExtension.lowercased()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        if verbatimExtensions.contains(ext) {
            let directory = try ensureAssetsDirectory(documentURL: documentURL)
            let destination = dedupedURL(in: directory, baseName: baseName, ext: ext)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return (relativePath(forAsset: destination, documentURL: documentURL), destination)
        }
        let data = try Data(contentsOf: sourceURL)
        return try storeImage(data: data, suggestedName: baseName, documentURL: documentURL)
    }

    /// Stores raw image data (pasteboard content) in the assets folder,
    /// as PNG. Returns the POSIX path relative to the document plus the file URL.
    @discardableResult
    static func storeImage(
        data: Data,
        suggestedName: String,
        documentURL: URL?
    ) throws -> (relativePath: String, fileURL: URL) {
        guard let documentURL else { throw StoreError.unsavedDocument }
        let directory = try ensureAssetsDirectory(documentURL: documentURL)
        let baseName = suggestedName.isEmpty ? "image" : suggestedName
        let destination = dedupedURL(in: directory, baseName: baseName, ext: "png")
        if data.starts(with: pngMagic) {
            try data.write(to: destination)
        } else {
            guard let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw StoreError.imageConversionFailed
            }
            try png.write(to: destination)
        }
        return (relativePath(forAsset: destination, documentURL: documentURL), destination)
    }

    /// The assets folder for a document (not necessarily existing yet).
    static func assetsDirectory(documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The assets folder, creating it on demand.
    private static func ensureAssetsDirectory(documentURL: URL) throws -> URL {
        let directory = assetsDirectory(documentURL: documentURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// First available name: `name.ext`, then `name-2.ext`, `name-3.ext`, …
    static func dedupedURL(in directory: URL, baseName: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// POSIX path of the asset relative to the document (`assets/foo.png`).
    static func relativePath(forAsset fileURL: URL, documentURL: URL) -> String {
        let directory = documentURL.deletingLastPathComponent()
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        if fileURL.path.hasPrefix(prefix) {
            return String(fileURL.path.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }
}
