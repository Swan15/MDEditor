# Manual Testing Checklist

Run through this before shipping a build. Check items off in order; note anything that regresses. The headless suite (`xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -destination 'platform=macOS' test`) covers the logic — this list is for the feel.

## Launch

- [ ] With no session to restore, the app launches to the welcome view (no document): app icon and name, "New Document" (⌘N) and "Open…" (⌘O) actions, and a Recent list matching File ▸ Open Recent (empty on first run). The formatting toolbar and status bar are hidden and the window title is "MDEditor".
- [ ] New Document (⌘N) from the welcome view opens a fresh "Untitled" document: cursor is in the editor; the status bar shows "Untitled", "0 words", "0 characters", no modified dot; the toolbar appears.
- [ ] The window cannot be resized below 480×560 pt: dragging a corner past that point stops (the sidebar, editor and status bar stay usable).

## Formatting (toolbar, Format menu, shortcuts)

- [ ] Type text, select it: Bold ⌘B, Italic ⌘I, Strikethrough ⇧⌘X toggle and highlight in the toolbar.
- [ ] Selecting whole lines (triple-click, or ⌘A over fully styled text) and pressing ⌘B/⌘I/⇧⌘X removes the formatting — the unstyled paragraph newline never blocks toggling off.
- [ ] With a collapsed selection (no selection), ⌘B/⌘I flip the trait for the next typed text.
- [ ] Heading menu / ⇧⌘1…⇧⌘6 applies heading sizes; ⇧⌘0 returns to body. Headings look bold but don't save as `**…**`.
- [ ] ⇧⌘7 ordered list, ⇧⌘8 bullet list: markers render, toggle again unwraps.
- [ ] ⇧⌘. block quote (indented, secondary color); ⇧⌘C code block (monospaced, background).
- [ ] ⌘K opens the link sheet with Text (prefilled from the selection, editable), URL and Title fields: on selected text it links/replaces that text; with nothing selected the typed text is inserted as the link. An existing link's URL/title are prefilled; clearing the Title removes it on save.
- [ ] ⇧⌘H inserts a horizontal rule; cursor lands below the rule.

## Layout

- [ ] Paragraphs and headings have clear breathing room between blocks (about half a line after body paragraphs, more around headings); list items within one list stay tight (no gap between items).
- [ ] Resize the window wide and narrow: beyond the max width (default 760 pt) the text column stops growing and centers with even side margins; below it the column fills the editor. Text always wraps at the column edge and no horizontal scrollbar ever appears — including at launch, before any resize. Images, rules and tables stay inside the column at every width.

## Editing behaviors

- [ ] Return at the end of a list item creates the next item (marker appears on first keystroke). Return on an empty item exits the list to body.
- [ ] Return in a task-list item creates a new **unchecked** item.
- [ ] Return at the end of a heading starts body text; Return mid-heading splits it and both halves stay headings.
- [ ] Return in a block quote continues the quote; Return on an empty quoted line exits to body.
- [ ] Return in a code block adds a line inside the block; Return on the block's empty last line exits below the block.
- [ ] Return on a horizontal rule starts a body paragraph below it.
- [ ] Tab inside a list item indents one level; ⇧Tab outdents; ⇧Tab at depth 0 removes the item from the list.
- [ ] Tab inside a code block inserts a literal tab. Tab in body text does nothing (a leading tab would reparse as code).
- [ ] Backspace at the very start of a heading/quote/code/list paragraph clears the style to body without deleting text; a second Backspace merges with the previous paragraph.
- [ ] Backspace at the start of the paragraph after a horizontal rule deletes the rule.
- [ ] Typing `"` or `--` in body text produces smart quotes/dashes; inside a code block or inline code they stay literal (and autocorrect is off there).
- [ ] Spell checking: a misspelled word gets the red underline in prose, but NEVER inside a code block, inline code or a raw HTML block — not on load, and not right after typing there (the underline may flash briefly, then clears).

## Autoformat-as-you-type

- [ ] In an empty paragraph, type `#` then Space: the `#` is replaced by heading 1 formatting; typing continues as a heading. Same for `##`…`######` (levels 2–6). Seven `#` does nothing.
- [ ] `-` + Space or `*` + Space: bullet list item (marker appears on first typed character); Return continues the list, Return on the empty item exits it.
- [ ] `1.` + Space: ordered list starting at 1. `3.` + Space: the list starts at 3 and saving writes `3. …`.
- [ ] `>` + Space: block quote; typing continues quoted.
- [ ] `` ``` `` + Space: empty code block (monospaced, shaded, autocorrect off); Return on the still-empty block converts back to body.
- [ ] `---` + Space: the paragraph becomes a horizontal rule and the caret lands below it. Works with smart dashes on (the stored `—-` still converts). `--` + Space does nothing.
- [ ] Typing the same triggers mid-paragraph, inside an existing heading/quote/list/code block/table cell, or with text selected does NOT autoformat — the characters insert normally.
- [ ] ⌘Z right after an autoformat restores the typed trigger text (`#`, `---`, …); a second ⌘Z removes it.
- [ ] Settings ▸ General ▸ "Autoformat as you type" OFF: every trigger inserts literally.

## Settings (⌘,)

- [ ] Settings opens with ⌘, and shows General (Autosave, Autoformat, Typewriter scrolling) and Appearance (Theme, Editor font, Font size, Limit editor width, Max width).
- [ ] Toggling each preference persists across relaunch (check `defaults read com.mdeditor.app` or just relaunch).
- [ ] Theme: Light and Dark force the app appearance regardless of the system; System follows the OS. All text, tables, code backgrounds and placeholders stay legible in each.
- [ ] Editor font: New York gives a serif body, SF Mono a monospaced body; code blocks and inline code stay monospaced in every choice; bold/italic still render (and save) correctly in each font.
- [ ] Font size stepper (11–18 pt): the whole document restyles live — body, headings (proportionally smaller/larger, still descending H1→H6), lists, quotes, tables. No dirty dot appears from the restyle alone.
- [ ] Limit editor width ON (default): in a wide window the text column caps at the Max width and centers with even margins. The Max width stepper (560–1200 pt, 20 pt steps, greyed out while the toggle is off) re-centers every open window live. OFF: the column fills the window width edge to edge (minus the usual padding), as before.

## Export & print

- [ ] File ▸ Export as PDF… on a document with headings, a table, a rule and an image: the save panel suggests the document's name; the written PDF opens in Preview with the content rendered like on screen (single continuous page).
- [ ] Export on an empty document does nothing (no panel, no error).
- [ ] File ▸ Print… (⌘P): the standard print panel appears; printing a multi-page document paginates at line boundaries (nothing clipped at page edges).

## Typewriter scrolling

- [ ] Settings ▸ Typewriter scrolling ON: while typing, the caret line stays vertically centered in the window. Clicking elsewhere or scrolling with the wheel/trackpad is NOT yanked back (only actual text edits re-center).
- [ ] Turn it back OFF (the default): scrolling behaves as usual.

## Window close and quit with unsaved changes

- [ ] The red close button is enabled. Closing a clean window closes it immediately; closing the LAST window leaves the app running (the dock icon stays; File ▸ New Window or clicking the dock icon reopens a window).
- [ ] Dirty untitled document, click the red button: NO alert — the window closes immediately (hot exit). Quit and relaunch: the window restores with the untitled document, its content intact and marked dirty.
- [ ] Relaunch with a restored untitled document and close the window again without editing: still no alert, and the content restores again on the next launch (the backup survives repeat hot exits).
- [ ] Restore an untitled backup, delete ALL its content, close the window: closes immediately (empty untitled = clean) and the backup is deleted — relaunch does NOT bring the document back.
- [ ] Restore an untitled backup, then ⌘S and pick a location: the document becomes a real file (the backup is retired); relaunch restores the file, not a backup.
- [ ] Dirty saved file with autosave ON (default), click the red button: saves silently and closes (no alert; the file on disk has the change).
- [ ] Dirty saved file with autosave OFF, click the red button: an alert offers Save / Don't Save / Cancel. Save shows the save flow → the window closes after saving; Don't Save closes without saving; Cancel aborts the close.
- [ ] Dirty untitled document, quit (⌘Q): NO alert — the app quits immediately, and relaunch restores the untitled document with its content (hot exit).
- [ ] Dirty saved file with autosave ON (default), quit: saves silently and quits (no alert; the file on disk has the change).
- [ ] Dirty saved file with autosave OFF, quit: an alert offers Save / Don't Save / Cancel. Save saves and quits; Don't Save quits without saving; Cancel aborts the quit.

## Multiple windows

- [ ] File ▸ New Window (⌥⇧⌘N) opens a second, fully independent window (welcome view, own sidebar). Repeat for a third. ⌘N (New Document) replaces the CURRENT window's document (after the dirty check) or fills its empty state.
- [ ] Type different text in each window: each keeps its own content, dirty dot and window title. With each saved to its own file, each window's autosave saves its own document independently.
- [ ] With two windows side by side, click one to focus it, then use Format ▸ Bold, the toolbar and Insert ▸ Image…: only the KEY window's editor changes; the background window's content is never touched. File ▸ Open… / Open Recent / Save / Save As… likewise act on the key window only.
- [ ] With a file open in window A, open the SAME file in window B (File ▸ Open…, Open Recent or a sidebar click): window A comes to the front and B keeps its current document — no duplicate opens.
- [ ] Close a background window with unsaved changes via its red button: a dirty file without autosave prompts and the alert names THAT window's document; a dirty untitled document just closes (hot exit — it comes back on relaunch).
- [ ] Close all windows: the app keeps running. With no window open, File ▸ New / Open… / Save and the Format / Insert menus are disabled (no crashes), while File ▸ New Window stays enabled and reopens a window.
- [ ] Two windows with different files open, quit (⌘Q) and relaunch: BOTH windows restore, each with its document (and workspace, if any). Close one window first, then quit and relaunch: only the remaining window restores.
- [ ] One window with a dirty untitled document and one with a saved file, quit (⌘Q) and relaunch: the untitled window restores with its content (hot exit, no alert at quit) and the file window restores from disk.
- [ ] ⌘Q with two dirty FILE windows and autosave OFF: an alert appears per dirty window in turn (each window comes to the front for its alert); Save / Don't Save / Cancel is answered per window and Cancel in any alert aborts the whole quit. Mixed case (one dirty saved file with autosave ON + one dirty untitled): nothing asks — the file saves silently and the untitled one stashes its hot-exit backup. (Restore is capped at 8 windows — covered by tests, impractical to check by hand.)

## Tables

- [ ] Format → Insert Table (⌥⌘T) or the toolbar grid button inserts a 3×2 table (header + one row) below the current paragraph; the caret lands in the first header cell. Works in an empty document too, and with the caret at the very end of a document (no trailing newline).
- [ ] Tables render Word-like: thin gridlines, padded cells, shaded header row with bold-looking text (but saving does **not** wrap headers in `**…**`).
- [ ] Column alignment from the file (`:---`, `:---:`, `---:`) shows as left/center/right text alignment in the cells.
- [ ] Tab moves the caret to the next cell (left→right, top→bottom); ⇧Tab moves back. Tab in the last cell appends a new row and moves into it. ⇧Tab in the first cell does nothing.
- [ ] Return inside a cell adds a line within the cell (not a new row); the table doesn't break apart. Saving keeps the cell on one GFM line.
- [ ] With the caret in a table, the Format menu enables Insert Row Above/Below, Delete Row, Insert Column Left/Right, Delete Column and Cycle Column Alignment (all disabled outside tables); the toolbar table menu shows the same.
- [ ] Insert/Delete Row and Column do what they say; the header row can't be deleted (Delete Row on it does nothing); Delete Column on the last remaining column does nothing.
- [ ] Cycle Column Alignment steps the caret's column through left → center → right.
- [ ] Backspace at the start of a cell does nothing (it never merges cells); Backspace at the start of the paragraph after a table does nothing; forward-delete at the end of a cell/before a table likewise.
- [ ] Select the whole table with the mouse and press Delete: the table disappears cleanly, leaving no stray empty cells. Save/reopen: no table syntax remains.
- [ ] Delete just the header row's text via a selection: the first body row becomes the header (shading moves up) and saving stays valid.
- [ ] Each table command is one undo step ("Undo Insert Row" etc.); ⌘Z restores the previous structure and caret.
- [ ] A document that ends with a table whose last cell is empty reopens with that cell intact.

## Undo / redo

- [ ] Typing undo (⌘Z) works in small steps as usual.
- [ ] Each format command (Bold, Heading, List, …) is one named undo step ("Undo Bold" in the Edit menu) and restores the styled content.
- [ ] Each behavior mutation (list split, indent, style clear, paste conversion) is one undo step; redo (⇧⌘Z) reapplies it.

## Paste

- [ ] Copy Markdown source (e.g. `# Title` + a list) from a plain-text editor and paste: it arrives styled, not as raw syntax.
- [ ] Paste plain prose ("hello world"): inserts as-is.
- [ ] Paste from a web page (rich text): keeps its formatting, no Markdown conversion.
- [ ] Paste Markdown-looking text while inside a code block: stays literal.
- [ ] Edit → Paste as Plain Text (⌥⇧⌘V) always inserts the raw text.

## Images

- [ ] Open a `.md` that references images in an `assets/` folder next to it: images render inline, scaled to the window width (never larger than their natural size). Resize the window narrower/wider: images rescale live, like Word.
- [ ] A very tall image is capped at ~80% of the visible editor height (aspect preserved).
- [ ] Open a single `.md` via File → Open… whose images are siblings of the file: the sandbox blocks reading them, so a one-time panel asks for access to the containing folder ("MDEditor needs access to this folder to show it in the sidebar and load images"). Grant it → images appear. Decline → dashed placeholders; the prompt does not reappear for that folder this session.
- [ ] Missing image file (`![gone](assets/gone.png)`): dashed placeholder box with the source path; saving keeps the original `![gone](assets/gone.png)` reference byte-for-byte.
- [ ] Remote image (`![r](https://example.com/x.png)`): placeholder showing the URL — nothing is fetched (offline-first; remote loading is a future opt-in).
- [ ] Paste a screenshot (⇧⌘4 then ⌘V): lands inline as an image; `assets/pasted-image.png` appears next to the document; saving writes `![pasted-image](assets/pasted-image.png)`. Paste a second one: `pasted-image-2.png`.
- [ ] Paste an image into a never-saved Untitled document: asked to save first; cancel → nothing is inserted.
- [ ] Drag an image file from Finder into the editor: inserts at the drop position; a `.jpg` stays a `.jpg` (copied, not re-encoded).
- [ ] Insert → Image… (⇧⌘I): pick any image file → inserted at the caret; TIFF/HEIC files are converted to PNG in `assets/`.
- [ ] Copy a web page's image (right-click → Copy Image) and paste: the image wins over the page's text/HTML flavors and inserts as an image.
- [ ] Double-click an image: popover with Alt Text and Title; Save → the file shows `![alt](src "title")`. Right-click an image → "Edit Image Alt Text…" opens the same popover. Clearing the title removes it from the markdown.
- [ ] Backspace right after an image deletes it; ⌘Z restores it. Deleting an image does NOT delete its file in `assets/` (orphan cleanup is a future feature).
- [ ] ⌘Z after an insert undoes it as one "Undo Insert Image" step (the asset file stays on disk).
- [ ] Dark mode: real images are unaffected; the dashed placeholder stays legible in both appearances.
- [ ] Known behavior: copy-pasting an image inside the document stores a NEW asset copy (`name-2.png`) with the filename as alt text — the original alt/title don't carry over.
- [ ] Pasting Markdown text containing image references loads those images immediately (same folder rules as opening a file).

## Status bar

- [ ] Word and character counts update live while typing; images and the rule placeholder don't count.
- [ ] Editing shows the modified dot next to the file name; saving clears it.

## Open / save round-trip

- [ ] Save (⌘S) a document with headings, lists, a quote, code, a table and a rule; close and reopen: content is identical.
- [ ] Open an existing `.md` file with mixed formatting: renders styled; Save writes back canonical Markdown (diff shows no spurious changes).
- [ ] File → New and File → Open… swap documents cleanly.
- [ ] Open a LONG document while the previous one is scrolled halfway down (⌘O, Open Recent, sidebar click or session restore): the editor shows the TOP of the new document with the caret at the very start — never mid-document where the old scroll position was.

## File management

- [ ] File → Save As… (⇧⌘S) always asks for a location; the window title follows the new name and saving keeps working there.
- [ ] File → Open Recent lists recently opened/saved files; picking one opens it; Clear Menu empties the list.
- [ ] File → Close Document (⌘W) closes the document and leaves the window on the welcome view (app icon, New/Open actions, recents); the toolbar and status bar hide and the window title resets to "MDEditor". It never resets to a phantom "Untitled" document. (Verify ⌘W triggers Close Document, not the system window close.)
- [ ] ⌘W on a dirty untitled document: an alert offers Save / Don't Save / Cancel. Save shows the save panel → after saving, the window still closes to the welcome view (the file is in Open Recent). Don't Save discards the content (and any hot-exit backup for it) → welcome view. Cancel keeps the document.
- [ ] ⌘W on a dirty file with autosave ON: saves silently, then the welcome view (the file on disk has the change). With autosave OFF: the same Save / Don't Save / Cancel alert as above.
- [ ] File → New (⌘N) on a dirty untitled document: the same alert — but Save runs the save panel and STAYS on the newly saved file (no new document is created); Don't Save discards to a fresh untitled; Cancel keeps the document.
- [ ] Dirty-switching with autosave ON (the default): edit a saved file, then File → Open… or click another file in the sidebar — the old file is saved silently (no prompt) and the switch happens. The dirty dot never appears for the old file.
- [ ] Dirty-switching with autosave OFF (defaults write: `defaults write com.mdeditor.app settings.autosaveEnabled -bool false`, relaunch): edit a saved file, then open another — an alert offers Save / Don't Save / Cancel. Save saves and switches; Don't Save switches without saving (reopening the old file shows the pre-edit content); Cancel aborts the switch.
- [ ] Same alert for a dirty **untitled** document even with autosave ON (there's no file to save silently to). Choosing Save and then cancelling the save panel aborts the switch.
- [ ] With no document open (welcome view), File ▸ Close Document / Save / Save As… / Export as PDF… / Print… are disabled; New and Open… stay enabled. Clicking a file in the welcome view's Recent list opens it.
- [ ] Autosave: edit a saved file and pause ~2 s — the dirty dot clears by itself and the file on disk has the change (check in another editor). An untitled document is never autosaved.

## Workspace (folder mode)

- [ ] File → Open Folder… picks a folder: the sidebar shows the folder name header and a tree of folders + Markdown files only (`.txt`, images, dotfiles and dotfolders like `.git` are hidden; an `assets/` folder IS shown). Sorting is folders first, then files, case-insensitive.
- [ ] Folders expand/collapse by clicking anywhere on the row (icon or name), like VSCode — the disclosure triangle and the right-click context menu still work; children load on first expand (a large folder doesn't stall the open).
- [ ] Clicking a file opens it in the editor; the open file's row stays highlighted. With a workspace open, File → Open… (⌘O) starts in the workspace folder and the opened file gets revealed (ancestors expand, row scrolls into view) when it's inside the workspace.
- [ ] ⌘O / Open Recent / welcome-view open of a file with NO workspace open (or a workspace in a different folder): the sidebar adopts the file's folder as the workspace root and reveals the file. The first time per folder per session macOS may ask for folder access ("…to show it in the sidebar and load images") — grant to see the tree; declining still opens the file and leaves the workspace as it was. A file inside the current workspace leaves the tree as-is.
- [ ] Live refresh: with the workspace open, add / rename / delete a file in Finder (or `touch` one in Terminal) — the tree updates within about a second. Deleting an expanded folder collapses it away cleanly.
- [ ] Context menu (right-click a row): New File creates `untitled.md` (then `untitled-2.md`, …) and opens it; New Folder creates `untitled folder` (then `untitled folder 2`, …) and reveals it. On a file row both target the file's folder.
- [ ] Rename… edits the name in an alert; colliding with an existing name shows an error and changes nothing. Renaming the open file (or a folder containing it) moves the document's save location too — ⌘S afterwards writes to the NEW path.
- [ ] Move to Trash asks for confirmation, then trashes (the item is in Finder's Trash, restorable). Trashing the open file keeps the content in the editor but detaches it (title becomes Untitled, ⌘S asks for a location).
- [ ] Reveal in Finder opens the containing folder with the item selected.
- [ ] The ✕ in the sidebar header closes the workspace (back to single-file mode); the open document stays open.
- [ ] Quit and relaunch with a workspace + file open: both restore (sandbox bookmarks), the tree is watched again, images next to the document load without a new grant prompt. Delete the workspace folder while the app is quit: relaunch restores nothing and shows no error (stale bookmarks clear silently).
- [ ] Opening a folder while the current document is dirty follows the same switching rules (silent save with autosave ON, alert otherwise); the document itself stays open.

## Updates

- [ ] The MDEditor (application) menu shows "Check for Updates…" above Settings…. Choosing it always fetches the latest GitHub release and reports: an update alert ("MDEditor X.Y.Z is available" + short notes excerpt), "You're up to date", or an error alert (e.g. with the network off).
- [ ] In the update alert: Download Update opens the GitHub release page in the browser (nothing is replaced in place); Later just dismisses; Skip This Version mutes that tag — relaunching (after clearing the throttle, see below) does not re-prompt for it, but a newer tag prompts again.
- [ ] Automatic check fires once ~3 s after launch (not once per window), at most once per 20 h, and is silent unless a newer, un-skipped release exists. Force it with `defaults write com.mdeditor.app settings.lastUpdateCheck -date "2001-01-01 00:00:00 +0000"` (clear a skip with `defaults delete com.mdeditor.app settings.skippedUpdateVersion`).
- [ ] With the network off, the launch check stays silent; only the manual check shows the error.

## Dark mode

- [ ] Toggle appearance (System Settings → Appearance): text, code backgrounds, links, quote tint, table gridlines/header shading and the status bar all remain legible.
