import AppKit

/// Headless PDF/print rendering from a text storage.
///
/// The content is copied into an off-screen TextKit 1 stack (the live
/// editing stack is never touched) laid out on a single tall container;
/// `dataWithPDF(inside:)` renders it as one continuous page, and
/// `NSPrintOperation` paginates the same view across paper pages.
enum PDFExport {
    /// Off-screen text view holding a copy of `source`, wrapped at
    /// `textWidth` and framed to the used height (plus the editor's insets).
    @MainActor
    static func printableView(from source: NSTextStorage, textWidth: CGFloat) -> NSTextView {
        let storage = NSTextStorage(attributedString: source)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        // Same inset as the editor, so the PDF looks like what's on screen.
        let inset = NSSize(width: 20, height: 24)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: textWidth + inset.width * 2, height: 16),
            textContainer: container
        )
        textView.textContainerInset = inset
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        textView.frame.size = NSSize(
            width: textWidth + inset.width * 2,
            height: used.height + inset.height * 2
        )
        return textView
    }

    /// Single-page PDF data of the whole document, wrapped at the live
    /// editor's text width (or 720 pt when no live layout exists, e.g. tests).
    /// Nil for an empty document.
    @MainActor
    static func pdfData(from source: NSTextStorage) -> Data? {
        guard source.length > 0 else { return nil }
        let liveWidth = source.layoutManagers.first?.textContainers.first?.containerSize.width
        let textWidth = liveWidth.flatMap { $0 > 0 ? $0 : nil } ?? 720
        let view = printableView(from: source, textWidth: textWidth)
        return view.dataWithPDF(inside: view.bounds)
    }
}

/// File-menu export and print operations.
extension AppState {
    /// File ▸ Export as PDF…: render the current content and write it out.
    @MainActor func exportPDF() {
        guard let storage = document.textStorage, let data = PDFExport.pdfData(from: storage) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = baseName + ".pdf"
        panel.directoryURL = document.fileURL?.deletingLastPathComponent() ?? workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t export the PDF."
            alert.runModal()
        }
    }

    /// File ▸ Print… (⌘P): standard print panel; the off-screen text view
    /// paginates itself at the paper's printable width.
    @MainActor func printDocument() {
        guard let storage = document.textStorage, storage.length > 0 else { return }
        let printInfo = NSPrintInfo.shared
        let textWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let view = PDFExport.printableView(from: storage, textWidth: max(textWidth, 200))
        NSPrintOperation(view: view, printInfo: printInfo).run()
    }
}
