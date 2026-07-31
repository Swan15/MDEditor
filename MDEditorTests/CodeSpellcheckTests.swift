import XCTest
@testable import MDEditor

/// Bug: continuous spell checking drew red underlines on "misspelled"
/// identifiers inside code blocks, inline code and raw blocks. Code is
/// literal — the checker must never mark it — while prose keeps its marks.
///
/// The checker applies its underlines as the `.spellingState` TEMPORARY
/// attribute through the layout manager; the tests apply that attribute
/// the same way (deterministic — the real checker marks asynchronously)
/// and assert the clear removes it from code ranges only.
final class CodeSpellcheckTests: XCTestCase {
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
        let suiteName = "MDEditorCodeSpellcheckTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A token no dictionary knows (the "misspelling").
    private let token = "zxqwv"

    /// Prose, a fenced code block, an inline-code span and a raw HTML
    /// block — each containing the misspelled token, in this order.
    private var markdown: String {
        """
        prose \(token) here

        ```
        let \(token) = 1
        ```

        inline `\(token)` span

        <div>\(token)</div>
        """
    }

    /// parse → build → style, on an offscreen TK1 stack.
    private func makeStack(_ markdown: String) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)))
        return (storage, layoutManager)
    }

    /// Character ranges of every occurrence of `token`, in document order.
    private func tokenRanges(in storage: NSTextStorage) -> [NSRange] {
        let string = storage.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: token, range: search)
            guard found.location != NSNotFound else { return ranges }
            ranges.append(found)
            search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
    }

    private func spellingMark(at index: Int, in layoutManager: NSLayoutManager) -> Any? {
        layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: index, effectiveRange: nil)
    }

    /// Marks the whole text the way the continuous checker would.
    private func markEverything(in storage: NSTextStorage, layoutManager: NSLayoutManager) {
        layoutManager.addTemporaryAttribute(
            .spellingState,
            value: NSNumber(value: NSAttributedString.SpellingState.spelling.rawValue),
            forCharacterRange: NSRange(location: 0, length: storage.length)
        )
    }

    // MARK: - Full sweep

    func testClearRemovesMarksFromCodeKeepsProse() throws {
        let (storage, layoutManager) = makeStack(markdown)
        let ranges = tokenRanges(in: storage)
        XCTAssertEqual(ranges.count, 4, "prose, code block, inline code, raw block")
        // Sanity: the semantic attributes are where the test expects them.
        XCTAssertNotNil(storage.attribute(MDAttr.codeBlock, at: ranges[1].location, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(MDAttr.inlineCode, at: ranges[2].location, effectiveRange: nil) as? Bool, true)
        XCTAssertNotNil(storage.attribute(MDAttr.rawBlock, at: ranges[3].location, effectiveRange: nil))

        markEverything(in: storage, layoutManager: layoutManager)
        CodeSpellcheck.clearMarksInCode(storage: storage, layoutManager: layoutManager)

        XCTAssertNotNil(spellingMark(at: ranges[0].location, in: layoutManager),
                        "prose keeps its spell-check marks")
        XCTAssertNil(spellingMark(at: ranges[1].location, in: layoutManager),
                     "code block is never marked")
        XCTAssertNil(spellingMark(at: ranges[2].location, in: layoutManager),
                     "inline code is never marked")
        XCTAssertNil(spellingMark(at: ranges[3].location, in: layoutManager),
                     "raw block is never marked")
    }

    /// The range-limited sweep (what the per-edit hook runs) clears only
    /// inside the range.
    func testClearLimitedToGivenRange() throws {
        let (storage, layoutManager) = makeStack(markdown)
        let ranges = tokenRanges(in: storage)
        markEverything(in: storage, layoutManager: layoutManager)

        CodeSpellcheck.clearMarksInCode(
            storage: storage, layoutManager: layoutManager, range: ranges[1]
        )

        XCTAssertNil(spellingMark(at: ranges[1].location, in: layoutManager),
                     "the code block inside the range is cleared")
        XCTAssertNotNil(spellingMark(at: ranges[2].location, in: layoutManager),
                        "inline code outside the range is left alone (the debounced full sweep handles it)")
    }

    // MARK: - Editor wiring

    /// The checker re-marks asynchronously AFTER an edit; the coordinator's
    /// debounced re-clear (fired by the textStorage didProcessEditing hook)
    /// must sweep those late marks out of code — and only code.
    @MainActor
    func testLateCheckerMarksAfterEditGetCleared() async throws {
        let appState = AppState(userDefaults: try makeDefaults())
        appState.document.pendingMarkdown = markdown
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.isRichText = true
        let coordinator = MarkdownTextView.Coordinator(appState: appState)
        coordinator.textView = textView
        storage.delegate = coordinator
        textView.delegate = coordinator
        appState.document.textStorage = storage
        coordinator.loadIfNeeded()

        // Type inside the code block: the delegate hook arms the debounced
        // full-document re-clear. (Ranges are computed after the edit —
        // the insertion shifts everything behind it by one.)
        let codeRange = tokenRanges(in: storage)[1]
        storage.replaceCharacters(in: NSRange(location: codeRange.location, length: 0), with: "x")
        let ranges = tokenRanges(in: storage)
        // The checker's marking pass lands later, after the edit.
        markEverything(in: storage, layoutManager: layoutManager)

        // The debounce is 600 ms; give it margin.
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertNil(spellingMark(at: ranges[1].location, in: layoutManager),
                     "late marks in the code block are swept once edits settle")
        XCTAssertNil(spellingMark(at: ranges[2].location, in: layoutManager),
                     "late marks in inline code are swept too")
        XCTAssertNotNil(spellingMark(at: ranges[0].location, in: layoutManager),
                        "prose keeps its marks — checking is never disabled")
    }
}
