import AppKit
import Foundation
import Observation

/// App-wide appearance override (Settings ▸ Appearance).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    /// The AppKit appearance to install; nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Body font choices for the editor (Settings ▸ Appearance). Code, raw
/// blocks and inline code always stay monospaced regardless of this choice.
enum EditorFontChoice: String, CaseIterable, Identifiable {
    case system, serif, monospaced
    var id: String { rawValue }

    /// The body font at the given size. The serif/monospaced choices resolve
    /// through system-font descriptors (New York / SF Mono) so bold/italic
    /// trait conversion keeps working.
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return NSFont.systemFont(ofSize: size)
        case .serif:
            return Self.designed(.serif, size: size)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private static func designed(_ design: NSFontDescriptor.SystemDesign, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }
}

/// Persisted application preferences (Settings scene, ⌘,).
@Observable
final class AppSettings {
    private static let autosaveKey = "settings.autosaveEnabled"
    private static let autoformatKey = "settings.autoformatEnabled"
    private static let typewriterKey = "settings.typewriterModeEnabled"
    private static let appearanceKey = "settings.appearance"
    private static let fontSizeKey = "settings.editorFontSize"
    private static let fontChoiceKey = "settings.editorFontChoice"

    /// Default body text size (matches the historical fixed constant).
    static let defaultFontSize: CGFloat = 13

    /// Allowed editor font size range (Settings stepper).
    static let fontSizeRange: ClosedRange<CGFloat> = 11...18

    /// Automatically saves dirty documents ~1.5 s after the last edit, but
    /// only documents that already have a file on disk. Default ON.
    var autosaveEnabled: Bool {
        didSet { defaults.set(autosaveEnabled, forKey: Self.autosaveKey) }
    }

    /// Word-style autoformat: a Markdown trigger (`# `, `- `, `1. `, `> `,
    /// `````` `, `--- `) typed as a paragraph's only content converts the
    /// paragraph instead of inserting the trigger text. Default ON.
    var autoformatEnabled: Bool {
        didSet { defaults.set(autoformatEnabled, forKey: Self.autoformatKey) }
    }

    /// Keeps the caret line vertically centered while typing. Default OFF.
    var typewriterModeEnabled: Bool {
        didSet { defaults.set(typewriterModeEnabled, forKey: Self.typewriterKey) }
    }

    /// Appearance override; applied to the whole app on change. Default System.
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            Self.applyAppearance(appearance)
        }
    }

    /// Editor body font size in points (clamped to `fontSizeRange`).
    /// Headings scale proportionally. Default 13.
    var editorFontSize: CGFloat {
        didSet {
            let clamped = min(max(editorFontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            if clamped != editorFontSize { editorFontSize = clamped }
            defaults.set(Double(clamped), forKey: Self.fontSizeKey)
        }
    }

    /// Editor body font family. Default System.
    var editorFontChoice: EditorFontChoice {
        didSet { defaults.set(editorFontChoice.rawValue, forKey: Self.fontChoiceKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autosaveEnabled = defaults.object(forKey: Self.autosaveKey) as? Bool ?? true
        self.autoformatEnabled = defaults.object(forKey: Self.autoformatKey) as? Bool ?? true
        self.typewriterModeEnabled = defaults.object(forKey: Self.typewriterKey) as? Bool ?? false
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        let size = defaults.object(forKey: Self.fontSizeKey) as? Double ?? Double(Self.defaultFontSize)
        self.editorFontSize = min(max(CGFloat(size), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.editorFontChoice = EditorFontChoice(rawValue: defaults.string(forKey: Self.fontChoiceKey) ?? "") ?? .system
    }

    /// Installs the appearance override app-wide (called at launch; changes
    /// after that go through the `appearance` didSet). Hops to the main
    /// queue: `NSApp` is main-actor and `didSet` here is nonisolated.
    static func applyAppearance(_ appearance: AppAppearance) {
        DispatchQueue.main.async {
            NSApp?.appearance = appearance.nsAppearance
        }
    }
}
