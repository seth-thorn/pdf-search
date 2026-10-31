# PDF Search — developer notes

PDF Search is a single-file native macOS app (SwiftUI + PDFKit + the SQLite that ships with macOS).
It has no dependencies, no Xcode project and no package manager.

## Files

- `PDFSearch.swift`: the entire app (~1,230 lines).
- `Info.plist`: bundle metadata (bundle id `local.pdfsearch`, min macOS 13; accepts PDFs/folders dropped on the Dock icon).
- `AppIcon.icns`: the icon.
- `build.sh`: compiles into `/Applications/PDF Search.app` (or `~/Applications` if `/Applications` isn't writable). Quits a running copy first.
- `Build PDF Search.command`: double-clickable wrapper. Checks for the developer tools, logs to `build.log`, opens the app.
- `test-pdfs/`: three tiny PDFs for checking search and highlighting.

## Building

Install Apple's Command Line Tools once (`xcode-select --install`), then double-click
`Build PDF Search.command`, or run it in Terminal. Under the hood:

```
swiftc -O -parse-as-library -swift-version 5 -target $(uname -m)-apple-macos13.0 \
  PDFSearch.swift -o "PDF Search.app/Contents/MacOS/PDFSearch" -lsqlite3
```

then copy `Info.plist` + icon into the bundle and ad-hoc sign (`codesign -s -`).
A universal (Apple Silicon + Intel) build compiles once per `-target` (`arm64-…`, `x86_64-…`) and joins them with `lipo -create`.

- `-swift-version 5` avoids Swift 6 strict-concurrency errors (the code uses GCD, not actors).
- `-parse-as-library` is needed because `@main` is in a file not named `main.swift`.
- Developed on macOS 26 with Swift 6.3; targets macOS 13+.
- An app you build yourself isn't quarantined, so there's no Gatekeeper warning.

## Data

| What | Where |
|---|---|
| Search index | `~/Library/Application Support/PDF Search/index.sqlite` (+ `-wal`, `-shm`) |
| Settings | user defaults `local.pdfsearch`: `scope` (last "Search in" folder), `highlightColor` |

Indexing never modifies PDFs. Highlighting writes highlight annotations into the PDF being viewed.

## How it works (architecture)

Everything is in `PDFSearch.swift`, in these sections (search for `// MARK:`):

1. **App**: `PDFSearchApp` (single `Window` scene) with menu commands:
   File ▸ Add PDFs or Folders… (⌘O), Rescan Folders (⌘R), Clear Index…; Edit ▸ Find in This
   PDF… (⌘F) and Highlight Selection / Highlighter (⌃⌘H). These replace the standard text-editing
   Find items. `AppDelegate` quits on last window close and handles files dropped on the Dock icon.
   Menu commands reach the window by bumping counters on `Library` (`findRequest`,
   `highlightRequest`) that `ContentView` watches with `.onChange`.
2. **Main window**: `ContentView`: `NavigationSplitView`.
   - Sidebar: `scopeBar` (Search in picker + ••• menu), results `List` of `HitRow`s, `statusBar`.
   - Detail: optional `findBar` + `pdfArea` (the PDF view with overlays for "Select a PDF" /
     "file moved"), plus a toolbar with: match counter, previous/next, Highlighter toggle,
     Highlight Color menu, Zoom to Fit, Open in Preview.
   - Find state: `showFind`, `findText`, `findFocused`. `activeTerms` = find text when the bar has
     text, else the main search terms. `.task(id: findText)` debounces find typing (150 ms).
   - Drag-and-drop: `.onDrop(of: [.fileURL])` on the whole window.
3. **PDF viewer**: `HighlightColor` (enum of the 5 colours, 50% alpha) and
   `HighlightingPDFView` (a `PDFView` subclass whose `menu(for:)` adds "Highlight" / "Remove
   Highlight"). `PDFKitView` wraps the single long-lived view owned by `Viewer`.
   - `Viewer.show(path:terms:page:wholeWords:)` first saves pending highlights (`flushSave`),
     then loads a **fresh** `PDFDocument` on a background queue, runs `findString` per term
     (case/diacritic-insensitive), optionally drops mid-word hits (`startsAtWord`, used for the
     main search but not ⌘F), sorts by page/position, colours them orange, and on the main thread
     sets the document, `highlightedSelections`, zoom, and jumps to the first hit. A generation
     counter (`gen`) discards stale loads.
   - **Zoom**: `autoScales` is off. New PDFs fit the window (`scaleFactorForSizeToFit`); a zoom
     the user makes (seen via `PDFViewScaleChanged` while `settingScale` is false) is kept in
     `userScale`. Window resizes re-fit only while `userScale == nil`. `zoomToFit()` clears it.
     (Pinch-zoom used to snap back because `autoScales = true` re-fits on every layout.)
   - **Highlights**: `addHighlight(sel)` makes one `PDFAnnotation(.highlight)` per page with one
     quad per line (`selectionsByLine`), points relative to the annotation's bounds, colour from
     `highlightColor`, author = macOS full name. The highlighter mode uses an `NSEvent` local
     monitor for `.leftMouseUp` inside the PDF view. `removeHighlight` removes the annotation.
     Both call `markUnsaved()` → `flushSave()` after 0.8 s, which writes the document to a hidden
     temp file `.<name>.pdfsearch-saving` in the same folder and swaps it in with
     `FileManager.replaceItemAt`. `flushSave` also runs before loading another PDF and on
     `willTerminate`. Failures show an alert (read-only / locked / encrypted).
     Saving changes the file's modification date, so the next rescan re-reads its text (harmless).
4. **Library**: the model (`ObservableObject`, singleton `Library.shared`): query, results,
   terms, scope, folders, counts, indexing progress, menu request counters. Owns two SQLite
   connections: `writer` (only on serial `writeQ`) and `reader` (only on `readQ`).
   - `add(urls)` expands folders (`findPDFs`, skipping hidden files and packages), records added
     folders, then calls `index(...)`.
   - `refresh()` removes entries for deleted files (only if the file's parent folder still exists,
     so an unplugged drive isn't wiped), rescans added folders, then calls `index(...)`.
   - `index(urls)` skips unchanged files (same mtime + size), extracts text in parallel
     (`OperationQueue`, cores − 2 workers, PDFKit `page.string`), writes each file in its own
     transaction under a lock, and publishes progress (and refreshes results every 100 files).
   - `runSearchNow()` calls `parse(query)` then `reader.search(fts, scope:)` or
     `reader.allFiles(scope:)`, plus `count(scope:)`. A generation counter (`searchGen`) drops stale results.
   - `parse(q)`: each word → `"word"*`, each quoted phrase → `"phrase"`, joined with spaces
     (= AND). It also returns the plain terms used for marking hits in the PDF.
   - `renameFolder`, `removeFolder`, `remove` (exclude files), `confirmClear`, `choose` (open panel).
5. **SQLite**: thin wrappers `DB` and `Stmt` over the system `libsqlite3` C API.

### Index schema

```sql
files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime REAL, size INTEGER,
      npages INTEGER,   -- -1 = couldn't open
      chars INTEGER)    -- total text length; < 50 shown as "no text"
folders(path TEXT PRIMARY KEY, name TEXT)   -- added folders; name = optional display name
excluded(path TEXT PRIMARY KEY)             -- files removed by hand; skipped on rescans
fts USING fts5(body, tokenize='unicode61 remove_diacritics 2')
```

**Key trick:** FTS rows have `rowid = fileID * 100000 + page` (page 0 = the file name,
pages 1…n = text). The file and page come from the rowid, and deleting a file's text is a fast
rowid *range* delete. (Storing `file_id` as an UNINDEXED FTS column makes every delete a full
table scan, so avoid that.)

**Scopes** filter with a byte-wise path range: `files.path >= '<folder>/' AND files.path < '<folder>0'`
('0' is the character after '/'). This matches exactly "inside this folder" (not `storage2`)
with no LIKE escaping. A default display name of `Zotero/storage` is "Zotero".

**Ranking:** rows come back `ORDER BY bm25(fts)` (max 5000 page-hits). They're grouped per file
in Swift by summing bm25 scores, so PDFs with many matching pages rank higher. Snippets use
FTS5 `snippet()` with `\x02`/`\x03` markers, turned into a bold, tinted `AttributedString`.

There's no stemming (porter) on purpose: index matching (prefix) and PDF marking (substring via
PDFKit) need to agree, and stemming would match words that can't be marked.

## Known limitations

- Scanned PDFs without a text layer aren't searchable (no OCR). They show "no text".
- Search is AND-only, same page. No OR/NOT/NEAR in the UI (FTS5 supports them; see ideas).
- New PDFs in an added folder are picked up on launch or ⌘R, not live.
- Password-protected PDFs are skipped ("can't read") and can't be highlighted.
- Very common words can produce thousands of marks; capped at ~5000 per document.
- Folder scopes are by path. If a folder is moved or renamed, remove it and add it again.
- Highlighting has no undo (use Remove Highlight). Only highlights, no notes/underline yet.

## Ideas for extending (and where to put them)

- **Undo/redo for highlights**: register add/remove with the window's `NSUndoManager` in
  `Viewer.addHighlight` / `removeHighlight`.
- **More annotation types**: underline/strikethrough (`.underline`, `.strikeOut` with the same
  quad points), notes (`.text`).
- **Highlights sidebar / export**: list a PDF's highlight annotations with their text
  (`page.selection(for: annotation.bounds)`), and export to Markdown/Obsidian.
- **OCR for scans**: in `Library.extract`, if a page's text is empty, render the page
  (`PDFPage.thumbnail(of:for:)`) and run Vision's `VNRecognizeTextRequest`.
- **Live updates**: watch added folders with FSEvents and call `index(...)` for changed paths.
- **OR / NOT / NEAR**: extend `Library.parse` to pass these through, and keep `terms` only for
  positive terms.
- **Sort / filter results**: by name, date, number of hits; by year.
- **Metadata**: PDF title/author from `PDFDocument.documentAttributes`. For Zotero, read
  `~/Zotero/zotero.sqlite` (copy it first; Zotero locks it) to show real titles/authors/years and
  open items in Zotero (`zotero://select/library/items/<key>`; the 8-character folder name under
  `storage/` is the attachment key).
- **Quick Look** (spacebar) on a result, **copy citation**, **export results** as a list.
