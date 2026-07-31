import Foundation
import Observation

/// A formatting command routed from menus and the toolbar to the active editor.
enum FormatCommand {
    case toggleBold, toggleItalic, toggleStrikethrough
    case body, heading(Int)
    case toggleOrderedList, toggleBulletList
    case toggleBlockQuote, toggleCodeBlock
    case insertLink, insertThematicBreak
    case insertImage
    case insertTable
    case insertRowAbove, insertRowBelow, deleteRow
    case insertColumnLeft, insertColumnRight, deleteColumn
    case cycleColumnAlignment
}

/// Toolbar/menu state snapshot for the current selection
/// (see `FormatCommands.inspect`).
struct SelectionFormatState: Equatable {
    var isBold = false
    var isItalic = false
    var isStrikethrough = false
    var headingLevel: Int?
    var isOrderedList = false
    var isBulletList = false
    var isBlockQuote = false
    var isCodeBlock = false
    var isInTable = false
}

/// Routes format commands from SwiftUI menus/toolbar to the active text
/// view's coordinator, and carries the selection state back for highlighting.
///
/// Focus routing: `WindowRegistry` installs the main window's editor as the
/// target whenever the main window changes, so global commands always land
/// in the key window (and no-op when no window is open).
@MainActor @Observable
final class FormatCommandBus {
    /// Shared bus (main-actor isolated, like everything that touches it).
    static let shared = FormatCommandBus()

    /// Formatting state at the active editor's cursor, kept current by the
    /// coordinator on every selection change.
    var selection = SelectionFormatState()

    /// The main window's editor, installed by `WindowRegistry` on focus
    /// change. Observed so menus can disable when no editor is available.
    weak var target: FormatCommandTarget?

    /// True when an editor is available for commands (menu enablement).
    var hasTarget: Bool { target != nil }

    /// Sends a command to the active editor (no-op when no editor exists).
    func send(_ command: FormatCommand) {
        target?.handleFormatCommand(command)
    }
}

/// Implemented by the editor coordinator to receive format commands.
@MainActor
protocol FormatCommandTarget: AnyObject {
    func handleFormatCommand(_ command: FormatCommand)

    /// Called after the document was saved (to a possibly new location) so
    /// the editor can re-resolve anything that needed a file location —
    /// e.g. image attachments that were placeholders while unsaved.
    func documentDidSave()

    /// Called when this editor becomes the command target (its window became
    /// main) so it re-publishes the cursor's format state to the bus.
    func publishSelectionState()
}
