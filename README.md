<p align="center">
  <img src="Assets/logo.png" width="180" alt="MDEditor icon">
</p>

<h1 align="center">MDEditor</h1>

<p align="center">
  A Markdown editor for macOS that works like Microsoft Word.<br>
  You edit rich text. The file on disk is always clean GitHub-Flavored Markdown.
</p>

<p align="center">
  <a href="https://github.com/Swan15/MDEditor/releases/latest"><img src="https://img.shields.io/github/v/release/Swan15/MDEditor" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-blue" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
</p>

---

Most Markdown editors make you stare at `**asterisks**` and `#` symbols, or split the window between markup and a preview. MDEditor hides the syntax completely: headings look like headings, tables look like tables, images sit inline. When you hit save, it writes canonical, diff-friendly Markdown that renders perfectly on GitHub.

## Features

- **True WYSIWYG** — headings, bold, italic, strikethrough, links, code, block quotes, lists, and rules are styled live as you type. No source view, no preview pane.
- **Real tables** — insert, add/remove rows and columns, Tab through cells (Tab on the last cell adds a row, like Word), column alignment. Saved as GFM pipe tables.
- **Inline images** — paste a screenshot or drag from Finder; files are copied into an `assets/` folder next to your document and referenced with relative paths.
- **Word habits work** — Return continues lists and quotes, empty item + Return exits, Tab / ⇧Tab indents, Backspace at the start of a styled paragraph clears the style first.
- **Autoformat** — type `#` + Space for a heading, `1.` + Space for a list, `>` + Space for a quote (can be disabled).
- **Folder workspace** — open a folder for a VSCode-style sidebar with all your `.md` files, live-updating as files change on disk.
- **Multi-window**, idle **autosave**, session restore, word count, dark mode, PDF export, print.
- **Paste smart** — pasting plain text that looks like Markdown converts it to styled text; rich pastes stay rich.
- **Self-updating** — checks GitHub Releases and tells you when a new version is out.

Under the hood it's 100% native Swift (SwiftUI + AppKit TextKit), sandboxed, with the Markdown round-trip covered by 300+ tests.

## Install

### Download the DMG

1. Grab `MDEditor-<version>.dmg` from the [latest release](https://github.com/Swan15/MDEditor/releases/latest).
2. Drag **MDEditor** into **Applications**.

The app is ad-hoc signed (no paid Apple Developer certificate yet), so the first launch needs one extra step: **right-click the app → Open → Open**. macOS only asks once. (If you prefer Terminal: `xattr -dr com.apple.quarantine /Applications/MDEditor.app`.)

### Homebrew

```bash
brew install --cask swan15/tap/mdeditor
```

Same first-launch note applies: right-click → Open.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Bold / Italic / Strikethrough | ⌘B / ⌘I / ⇧⌘X |
| Heading 1–6 · Body text | ⇧⌘1…6 · ⇧⌘0 |
| Ordered · Bullet list | ⇧⌘7 · ⇧⌘8 |
| Block quote · Code block | ⇧⌘. · ⇧⌘C |
| Link · Image · Table | ⌘K · ⇧⌘I · ⌥⌘T |
| Horizontal rule | ⇧⌘H |
| New window · Save As | ⌥⇧⌘N · ⇧⌘S |
| Paste as plain text | ⌥⇧⌘V |

## Build from source

Requirements: Xcode 16.3+, macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/Swan15/MDEditor.git
cd MDEditor
xcodegen
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' build
```

Run the tests:

```bash
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' test
```

`MDEditor.xcodeproj` is generated — edit `project.yml`, not the project. Release DMGs are built with `Scripts/build-release.sh <version>`; pushing a `v*` tag runs the GitHub Actions release workflow.

## How it works

The document you're editing is an attributed string carrying semantic attributes (heading level, quote depth, list structure…). Markdown only exists at the file boundary: Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) parses it on open, and a custom serializer emits canonical GFM on save. Constructs the editor doesn't render (raw HTML, exotic syntax) are preserved verbatim so nothing is ever lost. The editor uses the mature TextKit 1 stack because TextKit 2 cannot lay out tables.

## License

[MIT](LICENSE) © Alexander Swan
