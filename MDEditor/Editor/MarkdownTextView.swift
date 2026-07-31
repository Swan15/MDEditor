import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The WYSIWYG Markdown editing surface: an `NSTextView` on a classic
/// TextKit 1 stack, whose attributed string carries the document's semantic
/// attributes (the user never sees raw Markdown). TextKit 1 is required for
/// `NSTextTable` rendering; TextKit 2 has no table support.
struct MarkdownTextView: NSViewRepresentable {
    /// Global app state: the document shown plus session services
    /// (security scope for image access, workspace root).
    let appState: AppState

    /// The document shown in the editor.
    var document: DocumentModel { appState.document }

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Classic TextKit 1 stack: storage → layout manager → container,
        // handed to the text view. TextKit 2 is deliberately not used:
        // NSTextLayoutManager has no table support (cells lay out as stacked
        // full-width paragraphs, no borders), while NSLayoutManager renders
        // NSTextTable grids with borders, padding and backgrounds.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)
        let textView = MDTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480), textContainer: textContainer)

        // Word-like configuration.
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.textContainerInset = NSSize(width: ColumnLayout.baseInset, height: 24)
        textView.font = StyleEngine.bodyFont
        textView.typingAttributes = context.coordinator.defaultTypingAttributes
        // Word-like column cap from the preferences; the coordinator keeps
        // it live (see observeSettingsIfNeeded).
        textView.columnWidthLimit = appState.settings.limitEditorWidth ? appState.settings.editorMaxWidth : nil

        // Wrap to width, grow vertically inside the scroll view. The
        // container width is managed by MDTextView.applyColumnLayout (the
        // capped, centered column), so it must NOT track the text view.
        textContainer.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // Explicit: text wraps at the editor width, never scrolls sideways.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.observeSettingsIfNeeded()
        textView.pasteInterceptor = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.handlePaste(from: pasteboard) ?? false
        }
        textView.dropInterceptor = { [weak coordinator = context.coordinator] pasteboard, charIndex in
            coordinator?.handleDrop(from: pasteboard, at: charIndex) ?? false
        }
        textView.imageEditHandler = { [weak coordinator = context.coordinator] charIndex in
            coordinator?.presentImageAltEditor(at: charIndex)
        }
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.delegate = context.coordinator
        textStorage.delegate = context.coordinator
        document.textStorage = textStorage
        context.coordinator.loadIfNeeded()

        // Images cap their height at 80% of the visible height; the clip
        // view's bounds track window resizes (width rescaling is automatic:
        // the layout manager re-queries attachment bounds per layout pass).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MarkdownTextView.Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.document = appState.document
        context.coordinator.loadIfNeeded()
    }
}

extension MarkdownTextView {
    /// Bridges SwiftUI, the AppKit text delegates and format commands.
    ///
    /// All callbacks arrive on the main thread (AppKit UI is main-actor).
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, FormatCommandTarget {
        /// App state: session services (security scope, workspace root).
        var appState: AppState

        /// The document whose content is installed and reported dirty.
        var document: DocumentModel

        weak var textView: NSTextView?

        /// True while loading content (suppresses dirty marking/restyling).
        private var isLoading = false

        /// True while the style engine runs (its own edits must not recurse).
        private var isRestyling = false

        /// Retained while the alt-text popover is up (popovers don't retain
        /// themselves; a local would close immediately).
        private var altPopover: NSPopover?

        init(appState: AppState) {
            self.appState = appState
            self.document = appState.document
            super.init()
            // Per-window registration; the registry installs this coordinator
            // as the bus target whenever its window is main.
            appState.formatTarget = self
            // The editor remounts when a document opens in the empty state;
            // if this window is already main, no focus change will fire to
            // retarget the bus — re-assert the target now.
            WindowRegistry.shared.retargetIfMain(appState: appState)
        }

        /// Typing attributes for plain body text.
        var defaultTypingAttributes: [NSAttributedString.Key: Any] {
            [.font: StyleEngine.bodyFont, .foregroundColor: NSColor.labelColor]
        }

        // MARK: - Loading

        /// Installs `document.pendingMarkdown` (parse → build → style), once.
        func loadIfNeeded() {
            guard let textView, let textStorage = textView.textStorage,
                  let markdown = document.pendingMarkdown else { return }
            document.pendingMarkdown = nil
            isLoading = true
            textStorage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
            StyleEngine.styleAll(textStorage)
            isLoading = false
            textView.typingAttributes = defaultTypingAttributes
            textView.selectedRange = NSRange(location: 0, length: 0)
            loadImagesFromDisk()
            updateImageHeightCap()
            updateCodeSubstitutionToggles()
            updateSelectionState()
            updateStatistics()
        }

        // MARK: - NSTextStorageDelegate (restyle + dirty on edit)

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isLoading, !isRestyling else { return }
            isRestyling = true
            // Repair table structure damaged by raw edits (e.g. a selection
            // deletion that removed a row's cells) before restyling.
            TableController.sanitize(storage: textStorage, around: editedRange)
            StyleEngine.style(textStorage, range: editedRange)
            isRestyling = false
            document.isDirty = true
            updateSelectionState()
            updateStatistics()
            if appState.settings.typewriterModeEnabled { centerCaretLine() }
        }

        // MARK: - Typewriter mode

        /// Typewriter scrolling (Settings, default OFF): re-centers the caret
        /// line vertically after actual text edits. Selection-only changes
        /// (clicks, arrow keys) never re-center, so it doesn't fight the user.
        private func centerCaretLine() {
            guard let textView, let textStorage = textView.textStorage, textStorage.length > 0,
                  let layoutManager = textView.layoutManager,
                  let scrollView = textView.enclosingScrollView else { return }
            let location = min(textView.selectedRange().location, textStorage.length - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y += textView.textContainerOrigin.y
            let clipView = scrollView.contentView
            let visibleHeight = clipView.bounds.height
            guard visibleHeight > 0 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: max(lineRect.midY - visibleHeight / 2, 0)))
            scrollView.reflectScrolledClipView(clipView)
        }

        // MARK: - Editor preferences (fonts, column width)

        /// Re-applies editor preferences (fonts and the column cap) when
        /// they change. Installed once from `makeNSView`; re-registers after
        /// each change (one-shot observation, same pattern as the autosave
        /// controller).
        private var isObservingSettings = false

        func observeSettingsIfNeeded() {
            guard !isObservingSettings else { return }
            isObservingSettings = true
            observeSettings()
        }

        private func observeSettings() {
            withObservationTracking {
                _ = appState.settings.editorFontSize
                _ = appState.settings.editorFontChoice
                _ = appState.settings.limitEditorWidth
                _ = appState.settings.editorMaxWidth
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyFontSettings()
                    self.applyColumnSettings()
                    self.observeSettings()
                }
            }
        }

        /// Applies a font preference change: restyle everything, invalidate
        /// layout and refresh the default font and typing attributes.
        /// Attribute-only edits don't mark the document dirty.
        private func applyFontSettings() {
            guard let textView, let textStorage = textView.textStorage else { return }
            textView.font = StyleEngine.bodyFont
            StyleEngine.styleAll(textStorage)
            invalidateAllLayout()
            if textStorage.length > 0 {
                resetTypingAttributesFromCursor()
            } else {
                textView.typingAttributes = defaultTypingAttributes
            }
        }

        /// Pushes the column-width preference onto the text view; its
        /// `columnWidthLimit` didSet re-lays out the column in place.
        private func applyColumnSettings() {
            guard let textView = textView as? MDTextView else { return }
            textView.columnWidthLimit = appState.settings.limitEditorWidth ? appState.settings.editorMaxWidth : nil
        }

        // MARK: - NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCodeSubstitutionToggles()
            updateSelectionState()
        }

        /// Autoformat-as-you-type: a Markdown trigger as a paragraph's whole
        /// content + Space converts the paragraph (see `Autoformat`) and the
        /// Space is swallowed. Everything else inserts normally.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, let textStorage = textView.textStorage else { return true }
            let context = EditingBehavior.Context(
                storage: textStorage,
                selection: textView.selectedRange(),
                typingAttributes: textView.typingAttributes,
                undoManager: textView.undoManager,
                restoreSelection: selectionRestorer()
            )
            guard let result = Autoformat.transform(
                typedCharacter: replacementString,
                enabled: appState.settings.autoformatEnabled,
                in: context
            ) else { return true }
            if let typingAttributes = result.typingAttributes {
                textView.typingAttributes = typingAttributes
            }
            textView.selectedRange = result.selection
            textView.breakUndoCoalescing()
            document.isDirty = true
            updateStatistics()
            updateSelectionState()
            return false
        }

        /// Word-like key handling: Return/Tab/Shift-Tab/Backspace are routed
        /// through `EditingBehavior`; anything it declines uses the default.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let textStorage = textView.textStorage else { return false }
            let context = EditingBehavior.Context(
                storage: textStorage,
                selection: textView.selectedRange(),
                typingAttributes: textView.typingAttributes,
                undoManager: textView.undoManager,
                restoreSelection: selectionRestorer()
            )
            let result: EditingBehavior.Result?
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                result = EditingBehavior.insertNewline(in: context)
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                result = EditingBehavior.indent(in: context)
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                result = EditingBehavior.outdent(in: context)
            } else if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                result = EditingBehavior.deleteBackward(in: context)
            } else if commandSelector == #selector(NSResponder.deleteForward(_:)) {
                result = EditingBehavior.deleteForward(in: context)
            } else {
                return false
            }
            guard let result else { return false }
            if let typingAttributes = result.typingAttributes {
                textView.typingAttributes = typingAttributes
            }
            textView.selectedRange = result.selection
            if result.mutated {
                textView.breakUndoCoalescing()
                document.isDirty = true
                updateStatistics()
            }
            updateSelectionState()
            return true
        }

        /// Publishes the formatting state at the cursor to the bus — only
        /// while this editor is the command target (its window is main), so
        /// a background window never clobbers the shared state.
        func updateSelectionState() {
            guard FormatCommandBus.shared.target === self,
                  let textView, let textStorage = textView.textStorage else { return }
            FormatCommandBus.shared.selection = FormatCommands.inspect(textStorage, selection: textView.selectedRange())
        }

        /// FormatCommandTarget hook: this editor just became the bus target
        /// (its window became main) — re-publish the cursor state.
        func publishSelectionState() {
            updateSelectionState()
        }

        /// Publishes word/character counts to the document (status bar).
        func updateStatistics() {
            guard let textStorage = textView?.textStorage else { return }
            let string = textStorage.string
            document.wordCount = TextStatistics.wordCount(string)
            document.characterCount = TextStatistics.characterCount(string)
        }

        // MARK: - Code substitution toggles

        /// Code is literal: smart quotes/dashes, autocorrect and text
        /// replacement are disabled while the insertion point is in a code
        /// block, raw block or inline-code run, and re-enabled when it leaves.
        private func updateCodeSubstitutionToggles() {
            guard let textView, let textStorage = textView.textStorage else { return }
            let inCode = isCodeContext(textStorage: textStorage, location: textView.selectedRange().location)
            textView.isAutomaticQuoteSubstitutionEnabled = !inCode
            textView.isAutomaticDashSubstitutionEnabled = !inCode
            textView.isAutomaticSpellingCorrectionEnabled = !inCode
            textView.isAutomaticTextReplacementEnabled = !inCode
        }

        /// True when the insertion point sits in code (block, raw or inline).
        func isCodeContext(textStorage: NSTextStorage, location: Int) -> Bool {
            guard textStorage.length > 0 else { return false }
            let index = min(max(location, 0), textStorage.length - 1)
            let attributes = textStorage.attributes(at: index, effectiveRange: nil)
            if attributes[MDAttr.inlineCode] as? Bool == true { return true }
            let paragraph = textStorage.mdParagraphRange(for: NSRange(location: index, length: 0))
            guard paragraph.location < textStorage.length else { return false }
            let paragraphAttributes = textStorage.attributes(at: paragraph.location, effectiveRange: nil)
            return paragraphAttributes[MDAttr.codeBlock] != nil || paragraphAttributes[MDAttr.rawBlock] != nil
        }

        // MARK: - Paste conversion

        /// Paste interception: images on the pasteboard win over everything
        /// (they become real document images with on-disk assets); then plain
        /// text that parses as non-trivial Markdown is inserted as styled
        /// content; anything else goes through the default paste.
        func handlePaste(from pasteboard: NSPasteboard) -> Bool {
            guard let textView, let textStorage = textView.textStorage else { return false }
            if let content = ImagePasteboard.imageContent(from: pasteboard) {
                // Consumed even when the insert aborts (e.g. the required
                // save is cancelled): the default paste would insert a
                // source-less attachment the serializer cannot express.
                insertImageContent(content, at: textView.selectedRange())
                return true
            }
            guard let markdown = PasteConversion.markdownToConvert(from: pasteboard) else { return false }
            // Pasting into code keeps the text literal.
            if isCodeContext(textStorage: textStorage, location: textView.selectedRange().location) { return false }
            textView.breakUndoCoalescing()
            EditorUndo.registerUndo(
                storage: textStorage,
                selection: textView.selectedRange(),
                undoManager: textView.undoManager,
                actionName: "Paste",
                restoreSelection: selectionRestorer()
            )
            let cursor = PasteConversion.insert(markdown: markdown, storage: textStorage, selection: textView.selectedRange())
            textView.selectedRange = NSRange(location: cursor, length: 0)
            textView.breakUndoCoalescing()
            // The pasted Markdown may reference images; resolve them now.
            loadImagesFromDisk()
            updateImageHeightCap()
            resetTypingAttributesFromCursor()
            document.isDirty = true
            updateStatistics()
            updateSelectionState()
            return true
        }

        // MARK: - Images (load, insert, alt text)

        /// Loads image data for every unresolved image attachment. In
        /// single-file mode a sandbox denial triggers the one-time folder
        /// grant prompt (async, so view construction is never blocked);
        /// granted folders let the failures reload.
        private func loadImagesFromDisk() {
            guard let textStorage = textView?.textStorage else { return }
            let scope = appState.securityScope
            // Workspace mode (folder picked up front) already carries a grant.
            if let workspaceRoot = appState.workspaceRoot {
                scope.ensureAccess(to: workspaceRoot)
            }
            let report = ImageAttachmentController.loadImages(
                in: textStorage, documentURL: document.fileURL, scope: scope
            )
            if report.loadedAny || !report.failures.isEmpty {
                invalidateAllLayout()
            }
            guard report.hasPermissionFailures, appState.workspaceRoot == nil,
                  !scope.didPromptForFolderAccess else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentFolderAccessPanel() else { return }
                if ImageAttachmentController.retryLoads(report.failures, scope: scope) > 0 {
                    self.invalidateAllLayout()
                }
            }
        }

        /// FormatCommandTarget hook: after a save, placeholders left by an
        /// unsaved document (or a missing grant) get another chance.
        func documentDidSave() {
            guard let textStorage = textView?.textStorage else { return }
            let report = ImageAttachmentController.loadImages(
                in: textStorage, documentURL: document.fileURL,
                scope: appState.securityScope, retryPlaceholders: true
            )
            if report.loadedAny { invalidateAllLayout() }
            updateImageHeightCap()
        }

        /// Insert → Image…: pick an image file and insert it at the caret.
        private func presentImagePicker() {
            guard let textView else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            insertImageContent(.file(url), at: textView.selectedRange())
        }

        /// Drag & drop: image content lands at the drop position; anything
        /// else falls through to the text view's default handling.
        func handleDrop(from pasteboard: NSPasteboard, at charIndex: Int) -> Bool {
            guard let textView, let textStorage = textView.textStorage,
                  let content = ImagePasteboard.imageContent(from: pasteboard) else { return false }
            let location = min(max(charIndex, 0), textStorage.length)
            let selection = NSRange(location: location, length: 0)
            textView.selectedRange = selection
            insertImageContent(content, at: selection)
            return true
        }

        /// Shared insert pipeline (paste, drop, menu): store the image into
        /// the document's assets folder, then insert an attachment whose
        /// `source` is the relative path.
        private func insertImageContent(_ content: ImagePasteboard.Content, at selection: NSRange) {
            guard let textView, let textStorage = textView.textStorage else { return }
            // An attachment char inside code would serialize as a literal
            // U+FFFC; refuse instead of corrupting the block.
            guard !isCodeContext(textStorage: textStorage, location: selection.location) else {
                NSSound.beep()
                return
            }
            guard ensureSavedForImageInsert(), let documentURL = document.fileURL else { return }
            let store = { () throws -> (relativePath: String, fileURL: URL) in
                switch content {
                case .file(let url):
                    return try ImageAssetStore.storeImage(from: url, documentURL: documentURL)
                case .data(let data, let suggestedName):
                    return try ImageAssetStore.storeImage(data: data, suggestedName: suggestedName, documentURL: documentURL)
                }
            }
            let stored: (relativePath: String, fileURL: URL)
            do {
                stored = try store()
            } catch let error as NSError {
                // Single-file documents grant access to the .md only, so
                // creating assets/ next to it can need a folder grant —
                // ask (explicit user action, so not gated on once-per-session)
                // and retry once.
                guard Self.isSandboxPermissionError(error), presentFolderAccessPanel() else {
                    showImageInsertError(error)
                    return
                }
                do {
                    stored = try store()
                } catch {
                    showImageInsertError(error as NSError)
                    return
                }
            }
            let stem = URL(fileURLWithPath: stored.relativePath).deletingPathExtension().lastPathComponent
            let attachment = MDImageAttachment(source: stored.relativePath, altText: stem, title: nil)
            attachment.maxDisplayHeight = currentImageHeightCap()
            if ImageAttachmentController.load(
                attachment: attachment, fromFile: stored.fileURL, scope: appState.securityScope
            ) != .loaded {
                ImageAttachmentController.applyPlaceholder(attachment, reason: .unreadable)
            }
            withUndoSnapshot("Insert Image") {
                ImageAttachmentController.insert(attachment: attachment, storage: textStorage, selection: selection)
            }
            textView.selectedRange = NSRange(location: min(selection.location + 1, textStorage.length), length: 0)
            document.isDirty = true
            resetTypingAttributesFromCursor()
            updateSelectionState()
            updateStatistics()
        }

        /// Images live in an assets folder next to the document, so a
        /// never-saved document must be saved first. Returns false when the
        /// user cancels; the insert is then aborted.
        private func ensureSavedForImageInsert() -> Bool {
            guard document.fileURL == nil else { return true }
            let alert = NSAlert()
            alert.messageText = "Save this document before inserting an image."
            alert.informativeText = "Images are stored in an “assets” folder next to the document, so the document needs a location on disk first."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            appState.saveDocument()
            return document.fileURL != nil
        }

        /// The one-time folder grant: the sandbox gives single-file documents
        /// access to the .md only; images next to it need the folder.
        /// Returns true when a folder was picked.
        @discardableResult
        private func presentFolderAccessPanel() -> Bool {
            let scope = appState.securityScope
            scope.notePromptShown()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "MDEditor needs access to this folder to show and save images."
            panel.prompt = "Grant Access"
            panel.directoryURL = document.fileURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            scope.ensureAccess(to: url)
            return true
        }

        /// NSCocoaErrorDomain permission denials worth a folder grant.
        private static func isSandboxPermissionError(_ error: NSError) -> Bool {
            error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError)
        }

        /// Error alert for a failed image insert.
        private func showImageInsertError(_ error: NSError) {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t insert the image."
            alert.runModal()
        }

        // MARK: - Image display size

        /// Visible-height-driven image height cap: 80% of the viewport, so a
        /// tall image never fills more than the screen (Word-like); falls
        /// back to a fixed default before layout exists.
        func currentImageHeightCap() -> CGFloat {
            let visibleHeight = textView?.enclosingScrollView?.contentSize.height ?? 0
            return visibleHeight > 0 ? visibleHeight * 0.8 : ImageAttachmentController.defaultMaxDisplayHeight
        }

        /// Pushes the current height cap onto all image attachments and
        /// invalidates layout when it changed (window resize hook).
        func updateImageHeightCap() {
            guard let textView, let textStorage = textView.textStorage else { return }
            if ImageAttachmentController.setMaxDisplayHeight(currentImageHeightCap(), in: textStorage) {
                invalidateAllLayout()
            }
        }

        /// Clip-view bounds changes = window resizes (and scrolls, which the
        /// change check absorbs cheaply).
        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            updateImageHeightCap()
            // Resizes funnel through setFrameSize, but a clip-view change
            // that leaves the text view frame untouched (e.g. the view was
            // born at the clip width) still reaches the column here; the
            // application is idempotent.
            (textView as? MDTextView)?.applyColumnLayout()
        }

        /// Recomputes layout for the whole storage (attachment bounds changed).
        private func invalidateAllLayout() {
            guard let textView, let textStorage = textView.textStorage else { return }
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textStorage.length),
                actualCharacterRange: nil
            )
        }

        // MARK: - Image alt text

        /// Double-click / context-menu entry point: shows the alt-text
        /// popover for the image attachment at `charIndex`, anchored to the
        /// image's glyph rect.
        func presentImageAltEditor(at charIndex: Int) {
            guard let textView, let textStorage = textView.textStorage, let container = textView.textContainer,
                  let found = ImageAttachmentController.imageAttachment(at: charIndex, in: textStorage) else { return }
            let attachment = found.attachment
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: ImageAltEditorView(
                altText: attachment.altText,
                title: attachment.title ?? "",
                onApply: { [weak self] altText, title in
                    ImageAttachmentController.applyAltEdit(altText: altText, title: title, to: attachment)
                    self?.document.isDirty = true
                    popover.close()
                },
                onCancel: { popover.close() }
            ))
            var rect = textView.layoutManager?.boundingRect(forGlyphRange: found.range, in: container) ?? .zero
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            // Retained: a popover deallocated at scope end closes instantly.
            altPopover = popover
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }

        // MARK: - Undo

        /// Registers a snapshot undo step around a format-command mutation.
        private func withUndoSnapshot(_ actionName: String, _ mutation: () -> Void) {
            guard let textView, let textStorage = textView.textStorage else { return }
            textView.breakUndoCoalescing()
            EditorUndo.registerUndo(
                storage: textStorage,
                selection: textView.selectedRange(),
                undoManager: textView.undoManager,
                actionName: actionName,
                restoreSelection: selectionRestorer()
            )
            mutation()
            textView.breakUndoCoalescing()
        }

        /// Closure restoring the selection and typing attributes on undo.
        private func selectionRestorer() -> (NSRange) -> Void {
            let typingAttributes = textView?.typingAttributes
            return { [weak textView] range in
                guard let textView, let textStorage = textView.textStorage else { return }
                let location = min(max(range.location, 0), textStorage.length)
                let end = min(max(NSMaxRange(range), location), textStorage.length)
                textView.selectedRange = NSRange(location: location, length: end - location)
                if let typingAttributes {
                    textView.typingAttributes = typingAttributes
                }
            }
        }

        /// Runs a table structure command with an undo snapshot, then moves
        /// the caret to the position the command reports. Commands that don't
        /// apply (caret outside a table, header-row delete, last-column
        /// delete) return nil and leave the document untouched. Insert Table
        /// passes `requiresTable: false`: it creates a new table precisely
        /// because the caret is not inside one.
        private func applyTableCommand(
            _ actionName: String,
            requiresTable: Bool = true,
            _ operation: (NSTextStorage, NSRange) -> Int?
        ) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            if requiresTable {
                guard TableController.model(at: selection.location, in: textStorage) != nil else { return }
            }
            var caret: Int?
            withUndoSnapshot(actionName) { caret = operation(textStorage, selection) }
            guard let caret else { return }
            textView.selectedRange = NSRange(location: caret, length: 0)
            document.isDirty = true
            resetTypingAttributesFromCursor()
            updateSelectionState()
        }

        // MARK: - FormatCommandTarget

        func handleFormatCommand(_ command: FormatCommand) {
            guard let textView, let textStorage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            switch command {
            case .toggleBold:
                guard selection.length > 0 else {
                    toggleTypingTrait(.bold, mask: .boldFontMask)
                    updateSelectionState()
                    return
                }
                withUndoSnapshot("Bold") { FormatCommands.toggleBold(textStorage, selection: selection) }
            case .toggleItalic:
                guard selection.length > 0 else {
                    toggleTypingTrait(.italic, mask: .italicFontMask)
                    updateSelectionState()
                    return
                }
                withUndoSnapshot("Italic") { FormatCommands.toggleItalic(textStorage, selection: selection) }
            case .toggleStrikethrough:
                guard selection.length > 0 else {
                    var attributes = textView.typingAttributes
                    let struck = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                    attributes[.strikethroughStyle] = struck ? 0 : NSUnderlineStyle.single.rawValue
                    textView.typingAttributes = attributes
                    updateSelectionState()
                    return
                }
                withUndoSnapshot("Strikethrough") { FormatCommands.toggleStrikethrough(textStorage, selection: selection) }
            case .body:
                applyStructural(
                    { self.withUndoSnapshot("Body Text") { FormatCommands.applyBody(storage: textStorage, selection: selection) } },
                    emptyTypingAttribute: MDAttr.headingLevel, value: nil
                )
            case .heading(let level):
                applyStructural(
                    { self.withUndoSnapshot("Heading") { FormatCommands.applyHeading(level: level, storage: textStorage, selection: selection) } },
                    emptyTypingAttribute: MDAttr.headingLevel, value: level
                )
            case .toggleOrderedList:
                withUndoSnapshot("Ordered List") { FormatCommands.toggleList(ordered: true, storage: textStorage, selection: selection) }
            case .toggleBulletList:
                withUndoSnapshot("Bullet List") { FormatCommands.toggleList(ordered: false, storage: textStorage, selection: selection) }
            case .toggleBlockQuote:
                applyStructural(
                    { self.withUndoSnapshot("Block Quote") { FormatCommands.toggleBlockQuote(storage: textStorage, selection: selection) } },
                    emptyTypingAttribute: MDAttr.blockQuoteDepth, value: 1
                )
            case .toggleCodeBlock:
                applyStructural(
                    { self.withUndoSnapshot("Code Block") { FormatCommands.toggleCodeBlock(storage: textStorage, selection: selection) } },
                    emptyTypingAttribute: MDAttr.codeBlock, value: ""
                )
            case .insertLink:
                presentLinkPanel()
                return
            case .insertThematicBreak:
                var cursor = selection.location
                withUndoSnapshot("Horizontal Rule") {
                    cursor = FormatCommands.insertThematicBreak(storage: textStorage, selection: selection)
                }
                textView.selectedRange = NSRange(location: cursor, length: 0)
                textView.typingAttributes = defaultTypingAttributes
                document.isDirty = true
                updateSelectionState()
                return
            case .insertImage:
                presentImagePicker()
                return
            case .insertTable:
                applyTableCommand("Insert Table", requiresTable: false) { storage, range in
                    TableController.insertTable(storage: storage, selection: range)
                }
                return
            case .insertRowAbove:
                applyTableCommand("Insert Row") { storage, range in
                    TableController.insertRow(above: true, storage: storage, selection: range)
                }
                return
            case .insertRowBelow:
                applyTableCommand("Insert Row") { storage, range in
                    TableController.insertRow(above: false, storage: storage, selection: range)
                }
                return
            case .deleteRow:
                applyTableCommand("Delete Row") { storage, range in
                    TableController.deleteRow(storage: storage, selection: range)
                }
                return
            case .insertColumnLeft:
                applyTableCommand("Insert Column") { storage, range in
                    TableController.insertColumn(left: true, storage: storage, selection: range)
                }
                return
            case .insertColumnRight:
                applyTableCommand("Insert Column") { storage, range in
                    TableController.insertColumn(left: false, storage: storage, selection: range)
                }
                return
            case .deleteColumn:
                applyTableCommand("Delete Column") { storage, range in
                    TableController.deleteColumn(storage: storage, selection: range)
                }
                return
            case .cycleColumnAlignment:
                guard TableController.model(at: selection.location, in: textStorage) != nil else { return }
                withUndoSnapshot("Column Alignment") {
                    TableController.cycleAlignment(storage: textStorage, selection: selection)
                }
            }
            document.isDirty = true
            resetTypingAttributesFromCursor()
            updateSelectionState()
        }

        /// Structural commands work on paragraphs; with an empty document
        /// there is no paragraph yet, so prime the typing attributes instead
        /// (the typed text then carries the semantic attribute and the style
        /// engine picks it up on the first edit).
        private func applyStructural(
            _ command: () -> Void,
            emptyTypingAttribute key: NSAttributedString.Key,
            value: Any?
        ) {
            guard let textView, let textStorage = textView.textStorage else { return }
            if textStorage.length == 0 {
                var attributes = defaultTypingAttributes
                attributes[key] = value
                textView.typingAttributes = attributes
            } else {
                command()
            }
        }

        /// Flips a font trait in the typing attributes (collapsed selection).
        private func toggleTypingTrait(_ trait: NSFontDescriptor.SymbolicTraits, mask: NSFontTraitMask) {
            guard let textView else { return }
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? StyleEngine.bodyFont
            let applied = font.fontDescriptor.symbolicTraits.contains(trait)
            attributes[.font] = applied
                ? NSFontManager.shared.convert(font, toNotHaveTrait: mask)
                : NSFontManager.shared.convert(font, toHaveTrait: mask)
            textView.typingAttributes = attributes
        }

        /// Mirrors typing attributes off the text at the cursor, so typing
        /// continues in the style of the surrounding text. Attachment/link
        /// attributes are stripped: they must not bleed into fresh text.
        private func resetTypingAttributesFromCursor() {
            guard let textView, let textStorage = textView.textStorage, textStorage.length > 0 else { return }
            let index = min(textView.selectedRange().location, textStorage.length - 1)
            var attributes = textStorage.attributes(at: index, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .link)
            attributes.removeValue(forKey: MDAttr.linkTitle)
            textView.typingAttributes = attributes
        }

        /// Link insertion sheet on the editor's window: Text (prefilled from
        /// the selection, editable — typed text is inserted when nothing is
        /// selected), URL (required) and Title (optional). The dialog only
        /// gathers input; `FormatCommands.insertLink` performs the edit.
        private func presentLinkPanel() {
            guard let textView, let textStorage = textView.textStorage, let window = textView.window else { return }
            let selection = textView.selectedRange()
            let selectedText = selection.length > 0
                ? (textStorage.string as NSString).substring(with: selection)
                : ""

            let alert = NSAlert()
            alert.messageText = "Insert Link"
            alert.informativeText = selectedText.isEmpty
                ? "Enter the link text and destination; the link is inserted at the insertion point."
                : "The link is applied to the selected text; editing the text replaces it."
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 56, width: 280, height: 24))
            textField.placeholderString = "Link text"
            textField.stringValue = selectedText
            let urlField = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
            urlField.placeholderString = "https://example.com"
            let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            titleField.placeholderString = "Title (optional)"
            let stack = NSStackView(views: [textField, urlField, titleField])
            stack.orientation = .vertical
            stack.spacing = 4
            alert.accessoryView = stack
            alert.window.initialFirstResponder = selectedText.isEmpty ? textField : urlField

            // Prefill from an existing link at the selection.
            if textStorage.length > 0 {
                let index = min(selection.location, textStorage.length - 1)
                if let url = textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL {
                    urlField.stringValue = url.absoluteString
                } else if let string = textStorage.attribute(.link, at: index, effectiveRange: nil) as? String {
                    urlField.stringValue = string
                }
                if let title = textStorage.attribute(MDAttr.linkTitle, at: index, effectiveRange: nil) as? String {
                    titleField.stringValue = title
                }
            }

            alert.beginSheetModal(for: window) { [weak self, weak textView] response in
                guard let self, let textView, let textStorage = textView.textStorage,
                      response == .alertFirstButtonReturn, !urlField.stringValue.isEmpty else { return }
                let title = titleField.stringValue.isEmpty ? nil : titleField.stringValue
                var range = textView.selectedRange()
                self.withUndoSnapshot("Insert Link") {
                    range = FormatCommands.insertLink(
                        text: textField.stringValue.isEmpty ? nil : textField.stringValue,
                        url: urlField.stringValue, title: title,
                        storage: textStorage, selection: textView.selectedRange()
                    )
                }
                textView.selectedRange = range
                self.document.isDirty = true
                self.resetTypingAttributesFromCursor()
                self.updateSelectionState()
            }
        }
    }
}

/// The editor's text view: `NSTextView` plus Markdown-aware paste, image
/// drag & drop, and image alt-text editing.
final class MDTextView: NSTextView {
    /// Cap on the text column width (Settings ▸ Appearance ▸ Limit editor
    /// width); nil means the column fills the editor width. The coordinator
    /// keeps this in sync with the preferences; setting it re-lays out.
    var columnWidthLimit: CGFloat? {
        didSet { applyColumnLayout() }
    }

    /// Keeps the text view exactly as wide as the clip view, so nothing ever
    /// overflows sideways. The scroll view is created with a zero frame
    /// while the text view starts 720 pt wide, so the autoresizing mask's
    /// delta math alone would keep the view permanently 720 pt too wide
    /// (text wrapping far past the visible edge); snapping the width on
    /// every frame assignment covers the initial layout and every resize in
    /// one place. Each assignment also re-applies the column layout: the
    /// container no longer tracks the view width, it follows
    /// `ColumnLayout`.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let scrollView = enclosingScrollView {
            let width = scrollView.contentSize.width
            if width > 0, abs(newSize.width - width) > 0.5 {
                size.width = width
            }
        }
        super.setFrameSize(size)
        applyColumnLayout()
    }

    /// Eager first application: the initial layout may never change the
    /// frame (the view can be born at the clip width) and the clip view
    /// posts no bounds notification for it, so `setFrameSize` alone could
    /// leave the container at its creation width.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColumnLayout()
    }

    /// Applies the Word-like column: the container wraps at
    /// min(view width − base insets, `columnWidthLimit`) and the horizontal
    /// inset centers the capped column (floor: the base inset, so narrow
    /// windows look exactly like the unlimited layout). Idempotent — no-ops
    /// when the geometry is already right, so it is safe to call on every
    /// frame assignment and clip-view change without re-invalidation loops.
    func applyColumnLayout() {
        guard let textContainer else { return }
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: frame.width, maxWidth: columnWidthLimit)
        if abs(textContainer.containerSize.width - layout.containerWidth) > 0.5 {
            textContainer.containerSize = NSSize(
                width: layout.containerWidth,
                height: textContainer.containerSize.height
            )
        }
        if abs(textContainerInset.width - layout.horizontalInset) > 0.5 {
            textContainerInset = NSSize(width: layout.horizontalInset, height: textContainerInset.height)
        }
    }

    /// Inspects the pasteboard before a paste; returning true means the paste
    /// was consumed (image insert or plain-text Markdown conversion) and the
    /// default paste must not run.
    var pasteInterceptor: ((NSPasteboard) -> Bool)?

    /// Inspects a drag's pasteboard at the drop character index; returning
    /// true means the drop was consumed as a document image.
    var dropInterceptor: ((NSPasteboard, Int) -> Bool)?

    /// Opens the alt-text editor for the attachment at a character index.
    var imageEditHandler: ((Int) -> Void)?

    override func paste(_ sender: Any?) {
        if let pasteInterceptor, pasteInterceptor(.general) { return }
        super.paste(sender)
    }

    /// Image drops route through the same pipeline as paste; everything else
    /// keeps the text view's default behavior.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        if let dropInterceptor, dropInterceptor(sender.draggingPasteboard, charIndex) { return true }
        return super.performDragOperation(sender)
    }

    /// Double-click on an image opens its alt-text editor.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let imageEditHandler {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            if let hit = imageAttachmentIndex(near: charIndex) {
                imageEditHandler(hit)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Adds "Edit Image Alt Text…" when the click (or the caret) sits on an
    /// image attachment.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        let target = imageAttachmentIndex(near: charIndex) ?? imageAttachmentIndex(near: selectedRange().location)
        if let target {
            menu.insertItem(.separator(), at: 0)
            let item = NSMenuItem(
                title: "Edit Image Alt Text…",
                action: #selector(editImageAltText(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = target
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func editImageAltText(_ sender: NSMenuItem) {
        imageEditHandler?(sender.tag)
    }

    /// Character index of an image attachment at `index` or just before it
    /// (a click lands on either side of the attachment glyph).
    private func imageAttachmentIndex(near index: Int) -> Int? {
        guard let textStorage else { return nil }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
            if ImageAttachmentController.imageAttachment(at: candidate, in: textStorage) != nil {
                return candidate
            }
        }
        return nil
    }
}

/// NSTextStorageDelegate predates concurrency annotations (its requirement is
/// nonisolated), so the main-actor coordinator needs a preconcurrency
/// conformance. Edits only ever happen on the main thread here.
extension MarkdownTextView.Coordinator: @preconcurrency NSTextStorageDelegate {}
