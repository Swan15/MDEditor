import XCTest
@testable import MDEditor

/// Bug: opening a document (⌘O, recents, sidebar, session restore) could
/// leave the editor scrolled — the clip view kept the previous document's
/// scroll origin, so the new content started "above the viewable area".
/// A fresh load must land at the very top with the caret at the start
/// (no cursor position is ever persisted).
final class ScrollResetTests: XCTestCase {
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
        let suiteName = "MDEditorScrollResetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A long document: enough paragraphs to scroll for several screens.
    private func longMarkdown(_ prefix: String) -> String {
        (1...300).map { "\(prefix) paragraph \($0)" }.joined(separator: "\n\n")
    }

    /// The editor's TextKit 1 stack inside a scroll view and a real
    /// (offscreen) window, wired like `MarkdownTextView.makeNSView`.
    @MainActor
    private func makeEditorWindow(
        appState: AppState
    ) throws -> (window: NSWindow, scrollView: NSScrollView, textView: NSTextView, coordinator: MarkdownTextView.Coordinator) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MDTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480), textContainer: container)
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: ColumnLayout.baseInset, height: 24)
        container.widthTracksTextView = false
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
        storage.delegate = coordinator
        textView.delegate = coordinator
        appState.document.textStorage = storage
        coordinator.loadIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.layoutIfNeeded()
        addTeardownBlock { window.orderOut(nil) }
        return (window, scrollView, textView, coordinator)
    }

    /// Opening a second document while scrolled deep in the first must
    /// reset to the top of the new document (the `updateNSView` path:
    /// `openDocument` stages the Markdown, the coordinator consumes it).
    @MainActor
    func testOpeningDocumentWhileScrolledResetsToTop() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDEditorScrollResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fileB = dir.appendingPathComponent("b.md")
        try longMarkdown("Beta").write(to: fileB, atomically: true, encoding: .utf8)

        let appState = AppState(userDefaults: try makeDefaults())
        appState.document.loadMarkdown(longMarkdown("Alpha"))
        let (window, scrollView, textView, coordinator) = try makeEditorWindow(appState: appState)
        window.layoutIfNeeded()

        // Scroll deep into document A and prove the scroll stuck.
        textView.scrollToEndOfDocument(nil)
        window.layoutIfNeeded()
        let clipView = scrollView.contentView
        XCTAssertGreaterThan(clipView.bounds.origin.y, 500, "precondition: deep in document A")

        // Open document B (⌘O / recents / sidebar all land here).
        appState.openDocument(at: fileB)
        coordinator.loadIfNeeded()
        window.layoutIfNeeded()

        XCTAssertEqual(clipView.bounds.origin.y, -scrollView.contentInsets.top, accuracy: 1,
                       "a freshly opened document starts at the very top")
        XCTAssertEqual(textView.visibleRect.origin.y, -scrollView.contentInsets.top, accuracy: 1,
                       "the visible area is the top of the document")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0),
                       "the caret is at the start of the document")
    }

    /// The first load of a window (fresh mount, session restore) likewise
    /// starts at the top.
    @MainActor
    func testFirstLoadStartsAtTop() throws {
        let appState = AppState(userDefaults: try makeDefaults())
        appState.document.loadMarkdown(longMarkdown("Gamma"))
        let (window, scrollView, textView, _) = try makeEditorWindow(appState: appState)
        window.layoutIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, -scrollView.contentInsets.top, accuracy: 1)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }
}
