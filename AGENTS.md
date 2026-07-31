# AGENTS.md

Guidance for agents working on MDEditor.

## Build & test

```sh
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' build
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' test
```

- `project.yml` is the source of truth for the Xcode project. After editing it (and only then), regenerate with `xcodegen`. Sources use **synced folders**, so new `.swift` files under `MDEditor/` or `MDEditorTests/` need no project regeneration.
- Keep the whole test suite green; add tests for new headless logic (see `MDEditorTests/` for the parse → build → assert-through-serializer pattern). `TESTING.md` is the manual QA checklist — extend it when behavior changes.

## Architecture invariants — do not break these

1. **TextKit 1 only.** The editor is an `NSTextView` on the classic `NSTextStorage` → `NSLayoutManager` → `NSTextContainer` stack. TextKit 2 cannot render `NSTextTable` (tables would lose borders/padding), so never migrate the stack.
2. **The attributed string is the source of truth.** Markdown exists only at the file boundary: parse on open (`MarkdownParser` → `AttributedStringBuilder`), serialize on save (`MarkdownSerializer`). Never keep a parallel Markdown model during editing.
3. **Paragraph model: `\n` vs U+2028.** Blocks are `\n`-separated paragraphs; multi-line content inside a block (code blocks, raw blocks, table cells) uses U+2028 line separators. Never split paragraphs on U+2028 (that's why `enumerateMDParagraphs` exists instead of `NSString.paragraphRange`) and never insert a raw `\n` inside code/table content.
4. **Semantic attributes (`MDAttr` in `SemanticAttributes.swift`)** — `headingLevel`, `blockQuoteDepth`, `codeBlock`, `inlineCode`, `checkbox`, `listItemStart`, `linkTitle`, `rawBlock`, `thematicBreak`, `tableHeader`, `tableAlignments` — plus `.font` traits, `.link`, `.strikethroughStyle`, `.attachment`, and `.paragraphStyle`'s `textLists`/`textBlocks` are what the serializer reads. `StyleEngine` only adds *visual* attributes and must never rewrite semantics. Editing code (behaviors, format commands, autoformat) must produce exactly the attributes the builder would produce for the equivalent Markdown.
5. **Faux-bold headings and table headers** use a negative `.strokeWidth`, never the bold font trait: the serializer derives `**…**` from traits, so a truly bold heading font would wrap every heading in emphasis markers on save.
6. **Serializer output is canonical GFM** (ATX headings with one space, `-` bullets, sequential ordered numbers, ``` fences, `---` rules, one blank line between blocks, single trailing newline). Round-trip tests depend on it staying byte-stable.
7. **`.disableSmartOpts`** is passed when parsing so cmark never creates smart punctuation — the text view's own substitutions handle that at typing time.
8. **Sandbox + security scope.** The app sandbox is ON. Single-file documents only have access to the `.md` itself; anything next to it (images, `assets/`) goes through `SecurityScope` folder grants, and session restore uses app-scope bookmarks. Don't add file access that bypasses this.
9. **Per-window state & document lifecycle.** Every `WindowGroup` window owns an `AppState` (document, workspace, autosave, security scope, hot-exit backup ID); `AppSettings` is the only shared piece. Global menus and the toolbar never address a window directly — they go through `WindowRegistry`'s main-window record and the `FormatCommandBus` target it installs, so commands always land in the key window and no-op with none open. A window's document state is `none` (`hasDocument == false` — the welcome view), `untitled`, or `file`; an untitled document counts as dirty only while it holds content. Every lifecycle decision (New / Open / ⌘W / red button / quit) goes through `DocumentSwitchPolicy`'s pure functions: ⌘W closes to the `none` state (never a phantom untitled), and window close / quit never prompt for untitled documents — the content is stashed in `HotExitStore` and restored on relaunch (VSCode hot exit). Backups die on save, explicit Don't Save, clean close, or launch-time pruning of unreferenced IDs.

## Layout

- `MDEditor/App/` — app entry (`WindowGroup(for: WindowSession.self)` + menus + Settings scene), `WindowRootView` (per-window root), `AppState` (per-window state), `WindowRegistry` (window tracking, main-window command routing, close interception, duplicate-open focus), file operations, autosave, multi-window session restore, `HotExitStore` (untitled-document hot-exit backups in the app container), app delegate (quit-time dirty check over all windows), PDF export/print, update checker (`UpdateChecker` — headless `runCheck` + AppKit alerts, `UpdatePolicy`/`VersionComparison` pure, network behind `UpdateFeedProvider`).
- `MDEditor/Editor/` — the TextKit 1 stack (`MarkdownTextView` + coordinator), `ColumnLayout` (pure max-width/centering math applied by `MDTextView.applyColumnLayout`; the container never tracks the view width), `StyleEngine` (visual styling; fonts derive from `AppSettings` via `StyleEngine.fontSettings`), `EditingBehavior` and `Autoformat` (headless keystroke/transform engines), `FormatCommands`, tables, images, paste conversion.
- `MDEditor/Markdown/` — parser, builder, serializer, semantic attribute keys.
- `MDEditor/Models/` — document/workspace/file-tree models, `AppSettings` (UserDefaults-backed), switch/quit policy (pure, tested headless).
- `MDEditor/Views/` — SwiftUI shell: split view, sidebar, status bar, welcome (empty state), settings.
