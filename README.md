# MDEditor

A native macOS Markdown editor that works like a word processor: you edit styled text — headings, lists, tables, images — and never see raw syntax, while the file on disk stays canonical GitHub-Flavored Markdown. Microsoft Word on top, plain `.md` underneath.

<!-- Screenshots: drop images into docs/ and reference them here. -->

## Highlights

- **WYSIWYG editing** — headings, bold/italic/strikethrough, lists, block quotes, code blocks, horizontal rules, links, images and GFM tables render as formatted text, not syntax.
- **Word-like behaviors** — Return/Tab/Backspace do what Word does (continue/exit lists, split headings, indent/outdent), autoformat-as-you-type (`# ` → heading, `- ` → bullet, `1. ` → numbered list, `> ` → quote, ` ``` ` → code block, `---` → rule).
- **Tables** — real bordered tables with header shading, per-column alignment, Tab cell navigation and row/column commands.
- **Images** — paste, drop or insert; files are stored in an `assets/` folder next to the document and referenced with relative paths.
- **Workspace mode** — open a folder for a live file tree with create/rename/trash, plus Open Recent and session restore.
- **Autosave** — dirty documents with a file on disk save silently ~1.5 s after you stop typing (configurable).
- **Export & print** — one-click PDF export and standard printing.
- **Preferences** — theme (System/Light/Dark), editor font (System / New York / SF Mono) and size, autoformat, typewriter scrolling.

Files are always canonical GFM: ATX headings, `-` bullets, fenced code blocks, pipe tables — open the same file in any other Markdown tool and it reads cleanly.

## Requirements

- Xcode 16.3 or newer
- macOS 15 or newer

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` is the source of truth):

```sh
xcodegen          # only needed after editing project.yml
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor build
```

Or open `MDEditor.xcodeproj` and press ⌘R.

## Test

```sh
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' test
```

`TESTING.md` has the manual QA checklist for the things unit tests can't feel.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New / Open… / Close Document | ⌘N / ⌘O / ⌘W |
| Save / Save As… | ⌘S / ⇧⌘S |
| Export as PDF… / Print… | – / ⌘P |
| Settings | ⌘, |
| Bold / Italic / Strikethrough | ⌘B / ⌘I / ⇧⌘X |
| Body text / Heading 1–6 | ⇧⌘0 / ⇧⌘1…⇧⌘6 |
| Ordered / Bullet list | ⇧⌘7 / ⇧⌘8 |
| Block quote / Code block | ⇧⌘. / ⇧⌘C |
| Insert link / Horizontal rule | ⌘K / ⇧⌘H |
| Insert image / Insert table | ⇧⌘I / ⌥⌘T |
| Paste as plain text | ⌥⇧⌘V |
| Table: next / previous cell | Tab / ⇧Tab |
| List: indent / outdent | Tab / ⇧Tab |
