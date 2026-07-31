import XCTest
@testable import MDEditor

/// Font preferences → StyleEngine derivation: sizes scale proportionally
/// from the body size, families resolve through system font descriptors,
/// and trait conversion (bold/italic for `**` / `*` serialization) keeps
/// working on the chosen family.
final class FontSettingsTests: XCTestCase {
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
        let suiteName = "MDEditorFontTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func styledStorage(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(AttributedStringBuilder.build(MarkdownParser.parse(markdown)))
        StyleEngine.styleAll(storage)
        return storage
    }

    // MARK: - Defaults

    /// Without installed settings (headless use) the historical constants hold.
    func testDefaultsMatchHistoricalConstants() {
        XCTAssertNil(StyleEngine.fontSettings)
        XCTAssertEqual(StyleEngine.bodySize, 13)
        XCTAssertEqual(StyleEngine.headingSizes, [26, 22, 18, 16, 14, 13])
        XCTAssertEqual(StyleEngine.bodyFont, NSFont.systemFont(ofSize: 13))
        XCTAssertEqual(StyleEngine.codeFont.pointSize, 12)
    }

    // MARK: - Size math

    func testFontSizeScalesBodyCodeAndHeadings() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontSize = 16
        StyleEngine.fontSettings = settings

        XCTAssertEqual(StyleEngine.bodySize, 16)
        XCTAssertEqual(StyleEngine.bodyFont.pointSize, 16)
        XCTAssertEqual(StyleEngine.codeFont.pointSize, 15)
        // Headings keep the original ratios (26/13 … 13/13), half-point rounded.
        XCTAssertEqual(StyleEngine.headingSizes.first, 32)
        XCTAssertEqual(StyleEngine.headingSizes.last, 16)
        XCTAssertEqual(StyleEngine.headingFont(level: 1).pointSize, StyleEngine.headingSizes[0])
        for (size, base) in zip(StyleEngine.headingSizes, [26, 22, 18, 16, 14, 13] as [CGFloat]) {
            XCTAssertEqual(size / StyleEngine.bodySize, base / 13, accuracy: 0.03, "ratio for base \(base)")
        }
        XCTAssertGreaterThan(StyleEngine.headingSizes[0], StyleEngine.headingSizes[1])
        XCTAssertGreaterThan(StyleEngine.headingSizes[1], StyleEngine.headingSizes[2])
    }

    func testFontSizeIsClampedToRange() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontSize = 30
        XCTAssertEqual(settings.editorFontSize, 18)
        settings.editorFontSize = 4
        XCTAssertEqual(settings.editorFontSize, 11)
    }

    // MARK: - Families

    func testSerifChoiceResolvesSerifDesign() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontChoice = .serif
        StyleEngine.fontSettings = settings
        XCTAssertEqual(StyleEngine.bodyFont.familyName, ".AppleSystemUIFontSerif")
        XCTAssertFalse(StyleEngine.bodyFont.isFixedPitch)
    }

    func testMonospacedChoiceIsFixedPitch() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontChoice = .monospaced
        StyleEngine.fontSettings = settings
        XCTAssertTrue(StyleEngine.bodyFont.isFixedPitch)
    }

    /// Bold conversion must keep the chosen family — a dropped design would
    /// silently change the font of `**bold**` runs (and only those).
    func testBoldConversionPreservesChosenFamily() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontChoice = .serif
        StyleEngine.fontSettings = settings
        let storage = styledStorage("plain **bold**")
        let boldFont = storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(boldFont?.familyName, StyleEngine.bodyFont.familyName)
    }

    /// The whole styled document reflects the preferences.
    func testStyledStorageReflectsSettings() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorFontSize = 18
        settings.editorFontChoice = .serif
        StyleEngine.fontSettings = settings
        let storage = styledStorage("# Title\n\nBody")
        let heading = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let body = storage.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        XCTAssertEqual(body?.pointSize, 18)
        XCTAssertEqual(body?.familyName, ".AppleSystemUIFontSerif")
        XCTAssertEqual(heading?.pointSize, StyleEngine.headingSizes[0])
        XCTAssertGreaterThan(heading?.pointSize ?? 0, body?.pointSize ?? 0)
        // Code stays monospaced regardless of the body choice.
        let code = styledStorage("`x`")
        XCTAssertTrue((code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? false)
    }

    // MARK: - Persistence and preference defaults

    func testSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.autosaveEnabled = false
        first.autoformatEnabled = false
        first.typewriterModeEnabled = true
        first.appearance = .dark
        first.editorFontSize = 15
        first.editorFontChoice = .monospaced
        first.limitEditorWidth = false
        first.editorMaxWidth = 900

        let second = AppSettings(defaults: defaults)
        XCTAssertFalse(second.autosaveEnabled)
        XCTAssertFalse(second.autoformatEnabled)
        XCTAssertTrue(second.typewriterModeEnabled)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertEqual(second.editorFontSize, 15)
        XCTAssertEqual(second.editorFontChoice, .monospaced)
        XCTAssertFalse(second.limitEditorWidth)
        XCTAssertEqual(second.editorMaxWidth, 900)
    }

    func testNewPreferenceDefaults() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertTrue(settings.autosaveEnabled)
        XCTAssertTrue(settings.autoformatEnabled)
        XCTAssertFalse(settings.typewriterModeEnabled)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.editorFontSize, 13)
        XCTAssertEqual(settings.editorFontChoice, .system)
        XCTAssertTrue(settings.limitEditorWidth)
        XCTAssertEqual(settings.editorMaxWidth, 760)
    }

    func testEditorMaxWidthIsClampedToRange() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        settings.editorMaxWidth = 2000
        XCTAssertEqual(settings.editorMaxWidth, 1200)
        settings.editorMaxWidth = 100
        XCTAssertEqual(settings.editorMaxWidth, 560)
    }

    /// A persisted out-of-range cap (edited defaults, an older build) is
    /// clamped on load, like the font size.
    func testEditorMaxWidthIsClampedOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(Double(4000), forKey: "settings.editorMaxWidth")
        XCTAssertEqual(AppSettings(defaults: defaults).editorMaxWidth, 1200)
    }
}
