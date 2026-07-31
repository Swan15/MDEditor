import XCTest
@testable import MDEditor

/// Regression tests for six user-reported defects (see TESTING.md for the
/// matching manual checks):
/// 1. Bold/italic/strikethrough must toggle OFF again (selection and caret).
/// 2. Paragraphs must render with visible spacing between blocks; list
///    items within one list stay tight.
/// 3. The text container must track the scroll view width (no horizontal
///    scroller, text wraps at the editor width).
/// 4. The window has a sensible minimum size (480×560; manual check only).
/// 5. Insert Link gathers Text, URL and Title; the headless op replaces or
///    inserts the link text.
/// 6. Insert Table must work from the toolbar/menu routing, including an
///    empty document and the end of the document.
final class EditorRegressionTests: XCTestCase {
    /// StyleEngine.fontSettings is global; save/restore around each test.
    private var savedFontSettings: AppSettings?

    override func setUp() {
        super.setUp()
        savedFontSettings = StyleEngine.fontSettings
        StyleEngine.fontSettings = nil
    }

    override func tearDown() {
        StyleEngine.fontSettings = savedFontSettings
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorRegressionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// parse → build → storage.
    private func makeStorage(_ markdown: String = "") -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        return storage
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        MarkdownSerializer.serialize(storage)
    }

    private func roundTrip(_ source: String) -> String {
        MarkdownSerializer.serialize(AttributedStringBuilder.build(MarkdownParser.parse(source)))
    }

    // MARK: - Editor harness (the app's wiring without SwiftUI)

    /// An NSTextView + coordinator wired like `MarkdownTextView.makeNSView`.
    @MainActor
    private func makeEditor(markdown: String = "") throws -> (NSTextView, MarkdownTextView.Coordinator) {
        let appState = AppState(userDefaults: try makeDefaults())
        appState.document.pendingMarkdown = markdown
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        let coordinator = MarkdownTextView.Coordinator(appState: appState)
        coordinator.textView = textView
        storage.delegate = coordinator
        textView.delegate = coordinator
        appState.document.textStorage = storage
        coordinator.loadIfNeeded()
        return (textView, coordinator)
    }

    // MARK: - Bug 1: toggling emphasis OFF

    /// The app's exact sequence (style pass → toggle on → toggle off) for
    /// every editor font choice.
    private func assertTraitTogglesOff(
        _ trait: String,
        choice: EditorFontChoice,
        toggle: (NSTextStorage, NSRange) -> Void,
        marked: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontChoice = choice
        StyleEngine.fontSettings = settings
        defer { StyleEngine.fontSettings = nil }

        let storage = makeStorage("hello world")
        StyleEngine.styleAll(storage)
        let word = NSRange(location: 6, length: 5)
        toggle(storage, word)
        XCTAssertEqual(serialize(storage), "hello \(marked)world\(marked)\n",
                       "toggle on (\(trait), \(choice))", file: file, line: line)
        toggle(storage, word)
        XCTAssertEqual(serialize(storage), "hello world\n",
                       "toggle off (\(trait), \(choice))", file: file, line: line)
    }

    func testToggleBoldOffPerFontChoice() throws {
        for choice in EditorFontChoice.allCases {
            try assertTraitTogglesOff("bold", choice: choice, toggle: FormatCommands.toggleBold, marked: "**")
        }
    }

    func testToggleItalicOffPerFontChoice() throws {
        for choice in EditorFontChoice.allCases {
            try assertTraitTogglesOff("italic", choice: choice, toggle: FormatCommands.toggleItalic, marked: "*")
        }
    }

    func testToggleStrikethroughOffAfterRestyle() throws {
        for choice in EditorFontChoice.allCases {
            try assertTraitTogglesOff("strikethrough", choice: choice, toggle: FormatCommands.toggleStrikethrough, marked: "~~")
        }
    }

    /// Collapsed caret inside bold text: ⌘B must flip the typing attributes
    /// back to plain (the typing-attributes path of the coordinator).
    @MainActor
    func testCollapsedCaretTogglesTypingAttributesOff() throws {
        let (textView, coordinator) = try makeEditor(markdown: "plain **bold**")
        // Caret inside the bold run ("plain **bold**" → bold starts at 6).
        textView.selectedRange = NSRange(location: 8, length: 0)
        textView.typingAttributes = storage(textView).attributes(at: 8, effectiveRange: nil)
        coordinator.handleFormatCommand(.toggleBold)
        var font = textView.typingAttributes[.font] as? NSFont
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? true,
                       "⌘B in bold text must remove the bold typing attribute")
        coordinator.handleFormatCommand(.toggleBold)
        font = textView.typingAttributes[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                      "⌘B again must restore the bold typing attribute")
    }

    /// The reported failure: a line/triple-click selection covers the fully
    /// styled text *and* its trailing (unstyled) paragraph separator. The
    /// glyph-less newline run must not veto "already styled → remove" —
    /// otherwise the first ⌘B invisibly re-applies and the formatting stays.
    func testToggleBoldOffWhenSelectionIncludesTrailingNewline() {
        // Storage text: "world\nnext" (the "\n" run carries no bold font).
        let storage = makeStorage("**world**\n\nnext")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(serialize(storage), "world\n\nnext\n")
    }

    func testToggleItalicOffWhenSelectionIncludesTrailingNewline() {
        let storage = makeStorage("*world*\n\nnext")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleItalic(storage, selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(serialize(storage), "world\n\nnext\n")
    }

    func testToggleStrikethroughOffWhenSelectionIncludesTrailingNewline() {
        let storage = makeStorage("~~world~~\n\nnext")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleStrikethrough(storage, selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(serialize(storage), "world\n\nnext\n")
    }

    /// Whitespace-only runs (a plain space between two bold words) must not
    /// veto removal either — Word semantics key off the visible glyphs.
    func testToggleBoldOffWithPlainSpaceBetweenBoldWords() {
        let storage = makeStorage("**hello** **world**")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "hello world\n")
    }

    /// Removing one trait must keep the other (bold-italic → italic).
    func testToggleBoldOffKeepsItalic() {
        let storage = makeStorage("***both***")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(serialize(storage), "*both*\n")
    }

    /// Toggling ON across a fully plain selection still works (no regression
    /// from ignoring whitespace runs during detection).
    func testToggleBoldOnPlainLineWithTrailingNewline() {
        let storage = makeStorage("world\n\nnext")
        StyleEngine.styleAll(storage)
        FormatCommands.toggleBold(storage, selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(serialize(storage), "**world**\n\nnext\n")
    }

    @MainActor
    private func storage(_ textView: NSTextView) -> NSTextStorage {
        textView.textStorage!
    }

    // MARK: - Bug 2: paragraph spacing

    /// Spacing after load: body 6, headings per-level, list items tight.
    func testParagraphSpacingAfterLoad() throws {
        let storage = makeStorage("# Title\n\nBody one.\n\nBody two.\n\n- a\n- b")
        StyleEngine.styleAll(storage)
        // Storage: "# Title\nBody one.\nBody two.\n- a\n- b"
        let heading = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(heading?.paragraphSpacing, StyleEngine.headingSpacingAfter[0])
        XCTAssertEqual(heading?.paragraphSpacingBefore, StyleEngine.headingSpacingBefore[0])
        let bodyOne = storage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bodyOne?.paragraphSpacing, StyleEngine.bodySpacing, "body paragraph spacing after")
        let bodyTwo = storage.attribute(.paragraphStyle, at: 18, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bodyTwo?.paragraphSpacing, StyleEngine.bodySpacing)
        let listItem = storage.attribute(.paragraphStyle, at: 28, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listItem?.paragraphSpacing ?? -1, 0, "list items within one list stay tight")
    }

    /// The per-edit restyle path (what the text-storage delegate runs) must
    /// not drop the spacing.
    func testParagraphSpacingSurvivesRestyleAfterEdit() throws {
        let storage = makeStorage("First\n\nSecond")
        StyleEngine.styleAll(storage)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        StyleEngine.style(storage, range: NSRange(location: 0, length: 1))
        let first = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.paragraphSpacing, StyleEngine.bodySpacing,
                       "restyle after an edit must keep paragraph spacing")
        let second = storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(second?.paragraphSpacing, StyleEngine.bodySpacing)
    }

    /// Render-level proof: the vertical gap between two body paragraphs'
    /// line fragments includes the paragraph spacing, and two list items
    /// render tight. Also writes /tmp/mdeditor-spacing-check.png (two
    /// headings, paragraphs and a list) for manual QA.
    @MainActor
    func testRenderParagraphSpacingToPNG() throws {
        let markdown = "# Heading One\n\n## Heading Two\n\nBody paragraph.\n\n- one\n- two\n- three"
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        /// First line-fragment rect of the paragraph containing `index`.
        func lineRect(at index: Int) -> CGRect {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }

        // Storage text: "Heading One\nHeading Two\nBody paragraph.\n- one\n- two\n- three"
        // (display text without markers; offsets by inspection).
        let bodyIndex = "Heading One\n".count + "Heading Two\n".count
        let listOne = bodyIndex + "Body paragraph.\n".count
        let listTwo = listOne + "one\n".count
        let h1Rect = lineRect(at: 0)
        let h2Rect = lineRect(at: "Heading One\n".count)
        let bodyRect = lineRect(at: bodyIndex)
        let itemOneRect = lineRect(at: listOne)
        let itemTwoRect = lineRect(at: listTwo)
        print("SPACING-RECTS: h1=\(h1Rect) h2=\(h2Rect) body=\(bodyRect) item1=\(itemOneRect) item2=\(itemTwoRect)")
        // TextKit 1 folds paragraph spacing into the line fragments' heights
        // (spacing after extends the paragraph's last line, spacing before
        // extends the next paragraph's first line), so the spacing shows in
        // fragment heights and origin deltas rather than gaps between rects.
        XCTAssertGreaterThan(h1Rect.height, 36,
                             "H1 fragment = 26 pt line + spacing after (\(StyleEngine.headingSpacingAfter[0]))")
        XCTAssertGreaterThan(h2Rect.height, 44,
                             "H2 fragment = spacing before (\(StyleEngine.headingSpacingBefore[1])) + 22 pt line + spacing after")
        XCTAssertGreaterThan(bodyRect.height, 20,
                             "body fragment = 13 pt line + body spacing (\(StyleEngine.bodySpacing))")
        XCTAssertLessThan(itemOneRect.height, 20,
                          "list item fragment is just the line height (tight)")
        XCTAssertEqual(itemTwoRect.minY - itemOneRect.minY, itemOneRect.height, accuracy: 1,
                       "list items render tight (no gap between item lines)")

        let glyphRange = layoutManager.glyphRange(for: container)
        let used = layoutManager.usedRect(for: container)
        guard !used.isEmpty, glyphRange.length > 0 else {
            throw XCTSkip("Offscreen layout unavailable")
        }
        let size = NSSize(width: ceil(used.width) + 2, height: ceil(used.height) + 2)
        print("SPACING-PNG: used=\(used) size=\(size)")
        // Draw into a flipped image context: NSLayoutManager sets its text
        // matrix from the context's flippedness, so a raw (unflipped) bitmap
        // context renders glyphs mirrored. Force aqua: the sandboxed test
        // host can resolve labelColor in dark mode, which would draw
        // white-on-white.
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let cgContext = NSGraphicsContext.current?.cgContext {
                cgContext.setFillColor(NSColor.white.cgColor)
                cgContext.fill(CGRect(origin: .zero, size: size))
            }
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: CGPoint(x: 1, y: 1))
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: 1, y: 1))
        }
        image.unlockFocus()
        // Rasterize through TIFF: `cgImage(forProposedRect:)` with a nil
        // context picks an arbitrary pixel size in the test host.
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        print("SPACING-PNG: pixels=\(rep.pixelsWide)x\(rep.pixelsHigh)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let preferred = URL(fileURLWithPath: "/tmp/mdeditor-spacing-check.png")
        do {
            try data.write(to: preferred)
            print("RENDER-PNG-PATH: \(preferred.path)")
        } catch {
            // The sandboxed test host may not write to /tmp.
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mdeditor-spacing-check.png")
            try data.write(to: fallback)
            print("RENDER-PNG-PATH: \(fallback.path)")
        }
    }

    // MARK: - Bug 3: container width tracks the scroll view

    /// The editor's TextKit 1 stack inside a real (offscreen) window: the
    /// container width must track the scroll view's content width across
    /// resizes, and no horizontal scroller may appear. Mirrors
    /// `MarkdownTextView.makeNSView`, including the clip-view observer.
    @MainActor
    func testContainerTracksScrollViewWidthAcrossResize() throws {
        let appState = AppState(userDefaults: try makeDefaults())
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(
            "A long paragraph that must wrap at the editor width instead of running off the right edge of the window."
        )))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MDTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480), textContainer: container)
        textView.textContainerInset = NSSize(width: 20, height: 24)
        container.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let coordinator = MarkdownTextView.Coordinator(appState: appState)
        coordinator.textView = textView
        appState.document.textStorage = storage
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(MarkdownTextView.Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.layoutIfNeeded()

        func assertTracks(_ expectedContentWidth: CGFloat, _ label: String) {
            window.layoutIfNeeded()
            let contentWidth = scrollView.contentSize.width
            XCTAssertEqual(contentWidth, expectedContentWidth, accuracy: 1, "\(label): content width")
            XCTAssertEqual(textView.frame.width, contentWidth, accuracy: 1,
                           "\(label): text view fills the clip view")
            XCTAssertEqual(container.size.width, textView.frame.width - textView.textContainerInset.width * 2,
                           accuracy: 1, "\(label): container tracks the text view")
            XCTAssertFalse(scrollView.hasHorizontalScroller, "\(label): no horizontal scroller")
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            XCTAssertLessThanOrEqual(used.width, container.size.width + 1,
                                     "\(label): glyphs never exceed the container width")
        }

        assertTracks(800, "initial")
        window.setContentSize(NSSize(width: 500, height: 600))
        assertTracks(500, "narrower")
        window.setContentSize(NSSize(width: 1000, height: 700))
        assertTracks(1000, "wider")
        NotificationCenter.default.removeObserver(coordinator)
        window.orderOut(nil)
    }

    // MARK: - Bug 5: Insert Link with a Text field

    /// Replace-selection case: the dialog's Text field replaces the selected
    /// text while applying the link.
    func testInsertLinkReplacesSelectedText() {
        let storage = makeStorage("click here")
        let range = FormatCommands.insertLink(
            text: "this link", url: "https://example.com", title: nil,
            storage: storage, selection: NSRange(location: 6, length: 4)
        )
        XCTAssertEqual(serialize(storage), "click [this link](https://example.com)\n")
        XCTAssertEqual(range, NSRange(location: 6, length: 9))
        XCTAssertEqual(roundTrip(serialize(storage)), serialize(storage))
    }

    /// Insert-new-text case: nothing selected, the Text field supplies the
    /// link text (previously a fixed "link text" placeholder).
    func testInsertLinkInsertsGivenTextAtCaret() {
        let storage = makeStorage()
        let range = FormatCommands.insertLink(
            text: "Download", url: "https://example.com", title: "File",
            storage: storage, selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(serialize(storage), "[Download](https://example.com \"File\")\n")
        XCTAssertEqual(range, NSRange(location: 0, length: 8))
    }

    /// Text matching the selection (the dialog prefill) keeps it untouched.
    func testInsertLinkKeepsSelectedTextWhenTextMatches() {
        let storage = makeStorage("keep me")
        FormatCommands.insertLink(
            text: "keep me", url: "https://example.com", title: nil,
            storage: storage, selection: NSRange(location: 0, length: 7)
        )
        XCTAssertEqual(serialize(storage), "[keep me](https://example.com)\n")
    }

    /// Clearing the Title field removes an existing link title.
    func testInsertLinkClearsExistingTitle() {
        let storage = makeStorage("[text](https://a.com \"Old\")")
        StyleEngine.styleAll(storage)
        FormatCommands.insertLink(
            url: "https://b.com", title: nil,
            storage: storage, selection: NSRange(location: 0, length: 4)
        )
        XCTAssertEqual(serialize(storage), "[text](https://b.com)\n")
    }

    // MARK: - Bug 6: Insert Table

    /// Toolbar/menu routing: .insertTable must reach TableController even
    /// though the caret is not inside a table.
    @MainActor
    func testInsertTableCommandRouting() throws {
        let (textView, coordinator) = try makeEditor(markdown: "Intro paragraph")
        textView.selectedRange = NSRange(location: 0, length: 0)
        coordinator.handleFormatCommand(.insertTable)
        let storage = storage(textView)
        let models = TableController.models(in: storage)
        XCTAssertEqual(models.count, 1, "Insert Table must insert a table")
        XCTAssertEqual(models.first?.rowCount, 2)
        XCTAssertEqual(models.first?.columnCount, 3)
        // Caret lands in the first header cell; the document serializes.
        let caret = textView.selectedRange().location
        let tableRange = try XCTUnwrap(models.first?.range)
        XCTAssertTrue(NSLocationInRange(caret, tableRange), "caret inside the new table")
        XCTAssertEqual(serialize(storage), "Intro paragraph\n\n|  |  |  |\n| :--- | :--- | :--- |\n|  |  |  |\n")
    }

    /// Insert Table in an empty document (caret at 0, nothing to anchor on).
    @MainActor
    func testInsertTableCommandIntoEmptyDocument() throws {
        let (textView, coordinator) = try makeEditor()
        coordinator.handleFormatCommand(.insertTable)
        let storage = storage(textView)
        XCTAssertEqual(TableController.models(in: storage).count, 1)
        XCTAssertEqual(serialize(storage), "|  |  |  |\n| :--- | :--- | :--- |\n|  |  |  |\n")
        XCTAssertEqual(textView.selectedRange().location, 0, "caret at the first header cell")
    }

    /// Headless op: document-final paragraph without a trailing newline.
    func testInsertTableAtEndOfDocument() throws {
        let storage = makeStorage("Trailing text")
        StyleEngine.styleAll(storage)
        let caret = TableController.insertTable(storage: storage, selection: NSRange(location: storage.length, length: 0))
        XCTAssertEqual(TableController.models(in: storage).count, 1)
        XCTAssertEqual(serialize(storage), "Trailing text\n\n|  |  |  |\n| :--- | :--- | :--- |\n|  |  |  |\n")
        XCTAssertGreaterThan(caret, 0)
    }
}
