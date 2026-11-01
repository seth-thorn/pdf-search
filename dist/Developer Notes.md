# PDF Search — developer notes

PDF Search is a single-file native macOS app (SwiftUI + PDFKit + the SQLite that ships with macOS).
It has no dependencies, no Xcode project and no package manager.

## Files

- `PDFSearch.swift`: the entire app (~2,500 lines).
- `Info.plist`: bundle metadata (bundle id `local.pdfsearch`, version 2.1, min macOS 13; accepts PDFs/folders dropped on the Dock icon; registers the `pdfsearch://` URL scheme).
- `AppIcon.icns`: the icon.
- `build.sh`: compiles into `/Applications/PDF Search.app` (or `~/Applications` if `/Applications` isn't writable). Quits a running copy first, then runs `PDFSearch --selftest` (exercises the BibTeX parser, key rule, writer and link encoding, and parses your real `library.bib`).
- `Build PDF Search.command`: double-clickable wrapper. Checks for the developer tools, logs to `build.log`, opens the app.
- `test-pdfs/`: three tiny PDFs for checking search and highlighting.
- `tools/`: one-time Zotero import (`import_zotero.py`) and the shared key/BibTeX helpers (`bibtools.py`).

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
| Papers | `~/Papers` (added automatically); `~/Papers/Library` for your own papers |
| Bibliography | `library.bib`: `~/Obsidian Vault/library.bib` if that vault exists, else `~/Papers/library.bib` |
| Reference collections | any other `.bib` in an added folder or one level down (e.g. a conference archive's own `.bib`) |
| Paper notes | `@key.md` in `~/Obsidian Vault/Literature` if that vault exists, else `~/Papers/Notes` |
| Settings | user defaults `local.pdfsearch`: `papersFolder`, `libraryBib`, `notesFolder`, `writeNotes`, `scope`, `highlightColor`, `showMargin` |

All paths are in `enum Paths` and editable in Settings (⌘,). Indexing never modifies PDFs.
`file = {…}` fields in `library.bib`, the `pdf:` line of paper notes and `pdfsearch://` links store paths
**relative to the Papers folder** (`Library/x.pdf`, via `Paths.relative` / `Paths.absolute`), so a library
can move (another Mac, a USB stick). Absolute paths and JabRef's `:path:PDF` are still read.
Highlights and margin notes are written into the PDF being viewed.

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
     "file moved"), plus a toolbar with: ‹ match counter › (only while there are matches), Copy Citation (a plain
     menu: `[@key]`, `[[@key]]` via `CiteStyle.obsidianLink`, `\cite{key}`, key), Open in Obsidian (`openPaperNote`;
     `ensurePaperNote` creates the note if needed), Notes (column toggle), ••• (Zoom to Fit, Open in Preview,
     Show in Finder). A README link in the status bar (and Help ▸ PDF Search README, ⌘?) opens `ReadmeCard`, a plain-English
     one-page workflow, as a sheet. The notes column is resized with `ColumnHandle`
     (width in `@AppStorage("marginWidth")`); the PDF pane has 6 pt leading padding so PDFView doesn't fight the
     sidebar divider's resize cursor.
   - Find state: `showFind`, `findText`, `findFocused`. `activeTerms` = find text when the bar has
     text, else the main search terms. `.task(id: findText)` debounces find typing (150 ms).
   - Drag-and-drop: `.onDrop(of: [.fileURL])` on the whole window.
3. **PDF viewer**: `HighlightLevel` (two kinds of highlight, 50% alpha: `.interesting` yellow, `.essential`
   red-pink; `HighlightLevel.of(annotation)` reads the level from the colour: yellow hue → Interesting, any
   other colour → Essential, sticky notes → none) and
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
     quad per line (`selectionsByLine`), points relative to the annotation's bounds, Interesting
     (yellow), author = macOS full name. `setLevel(_:_:)` recolours one (the card's **Essential**
     checkbox, or right-click → Mark as …). The highlighter mode uses an `NSEvent` local
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
5. **Bibliography**: `BibEntry`, `BibIndex` (lookup by PDF path or by file name = key), `BibParser`
   (byte-level BibTeX parser with light LaTeX decoding), `CiteKey` (the key rule; mirrored in
   `tools/bibtools.py`), `BibWriter` (formatting, escaping `& % # _`, appending to `library.bib`).
   `Library.reloadBib()` re-reads `library.bib` plus reference `.bib` files whenever one changes
   (checked on launch, after indexing and whenever the app comes to the front), then
   `applyBibToIndex` rewrites each file's page-0 row with title/authors/year/key so they're searchable.
   Results get their `entry`; library entries without an indexed PDF are added as `Hit`s with
   negative ids and shown as an `EntryCard`. `cite()` copies `[@key]` / `\cite{key}`;
   `ensureInLibrary()` copies a reference entry into `library.bib` with a new key first.
6. **Marginalia**: `MarginNote`, `Marginalia` (collect markup annotations in reading order, recover the
   quoted text from quad points, build and update `@key.md`), `MarginColumn` / `MarginRow` (the
   notes column, `NoteCard`s with an always-editable note box and a Remove button). H (handled in
   `HighlightingPDFView.keyDown`), the "Highlight selected text" button or ⌃⌘H →
   `Viewer.highlightAndComment()` → `focusNoteID` puts the cursor in the new card's note box;
   `updateComment` writes `annotation.contents` as you type and saves 1.5 s after you stop.
   Clicking a highlight in the PDF (a local `leftMouseUp` monitor) focuses its card. After each save, `Library.afterSave()`
   re-indexes the file (notes are appended to their page's text, so they're searchable) and
   rewrites only the block between `<!-- marginalia:start -->` and `<!-- marginalia:end -->` in the
   note (`## Summary`, then `## Essential` and `## Interesting`, or just `## Marginalia` when nothing is
   Essential; each in page order); everything outside it is the user's. Links in notes are `pdfsearch://open?file=…&page=N`,
   handled by `Library.handle(_:)` (from `.onOpenURL` and the app delegate) → `linkRequest`.
7. **Projects** are left to the notes app (collections were removed in 2.7): a project note holds `[[@key]]`
   links, and *Copy Citation ▸ [[@key]]* copies one (creating the paper note first, so the link resolves).
8. **Adding papers**: `EntryKind`, `Lookup` (DOI / arXiv / ISBN detection; `doi.org` content negotiation
   for CSL-JSON, used for Crossref, DataCite/Zenodo and arXiv `10.48550/arXiv.<id>` DOIs; Crossref
   `query.bibliographic` title search; Open Library `api/books?jscmd=data` then Google Books for ISBNs;
   `scan()` reads the first pages for identifiers and a title), `AddPaperModel` (card state; its async
   methods are `@MainActor`), `AddPaperView` (the sheet). `Library.requestAdd/nextAdd` queue cards,
   `handleDropped` routes drops (folders → index; PDFs with an entry → index; new PDFs → cards, or a
   choice when there are more than three), `addToLibrary` moves/copies to `Library/<key>.pdf`, appends to
   library.bib, refreshes and opens the paper.
9. **Paper summary**: "About this paper" (`SummaryBox`) is stored as a page-1 Text annotation whose
   contents start with `Summary` (`Marginalia.isSummary/summary/summaryAnnotation`); excluded from the
   highlight cards, indexed for search, and written as `## Summary` at the top of the note's managed block.
10. **Settings**: `SettingsView` (⌘,) edits the `Paths` defaults.
11. **My Notes** (Search in ▸ My Notes, ⇧⌘F): searches only the user's own material.
    `Library.extract` returns each PDF's highlights/notes and summary as `IndexedNote`s, stored by
    `DB.store` in the `notes` table. `OwnNotes.parse` takes the user's writing in a paper note
    (everything after the managed block, or the whole body if there is none; one row per paragraph;
    lone headings skipped). `Library.syncOwnNotes()` re-reads changed `.md` files after a rescan, when the
    app comes to the front and when the notes folder changes (and does nothing if the folder is missing).
    The scope is the sentinel `Library.myNotesScope`: an empty query lists annotated papers
    (`notedPapers`), a query gives one `Hit` per note (`noteHits`, `Hit.note: NoteInfo`). Normal searches run
    `attachNotes`, which sets `Hit.noteSnippet` and `noteCount` and appends papers matching only in notes.
    Selecting a note calls `Viewer.show(..., note: NoteTarget)`, which goes to the annotation and sets
    `spotlightNoteID` (outlines and scrolls to the card without taking keyboard focus, unlike
    `focusNoteID`). Right-click: *Copy Quote with Citation* (`“…” [@key, p. N]`), *Open Paper Note*
    (`Marginalia.openNote`: `obsidian://open?path=` when the file is inside a folder containing
    `.obsidian`, else the default app).
12. **Result pictures**: `Thumb` (36×48 pt, at the left of each `HitRow`) asks `Thumbnails.shared`, which
    renders page 1 with `PDFPage.thumbnail` onto white (160 px long side, JPEG) on a 3-wide `OperationQueue`
    and caches it in memory (`NSCache`) and in `~/Library/Caches/PDF Search/Thumbnails` (key = path + mtime +
    size, FNV-1a file names). Entries without a PDF get an Open Library cover by ISBN
    (`covers.openlibrary.org/b/isbn/<isbn>-M.jpg?default=false`; a 404 is remembered, being offline isn't)
    or a symbol.
13. **Recently Edited** (Search in ▸ Recently Edited, ⇧⌘E; sentinel scope `Library.recentScope`): papers whose
    highlights/notes changed, newest first, labelled by `Library.when(_:)`. The time is
    `max(files.edited, edits.time)`: `files.edited` is the newest annotation `modificationDate` found when indexing
    (so edits made on another Mac count after a rescan), and `edits(path, time)` is written by `Library.afterSave`
    on every save (so removing a highlight counts too). Opening a PDF doesn't count.
14. **Highlight outline**: clicking a `NoteCard` calls `Viewer.reveal`, which scrolls only if the highlight is off screen,
    sets `spotlightNoteID` (card outline) and calls `flash(_:)`: a thin dark border view added to `pdfView.documentView`
    that fades in (0.15 s), holds and fades out (0.3 s). Nothing is written to the PDF.
15. **#Tags**: `Marginalia.tags(in:)` / `hasTag` follow Obsidian's tag rules. Note cards show `TagChip`s (`FlowLayout`);
    a chip runs `Library.showTag` (My Notes, query `#tag`). `noteHits(…, tags:)` keeps only notes really carrying the tag
    (FTS drops the `#`). Obsidian indexes the same tags in the mirrored paper notes, with no extra files.
16. **Obsidian vaults**: `ObsidianVaults.list()` reads Obsidian's `~/Library/Application Support/obsidian/obsidian.json`.
    Settings ▸ Obsidian vault and the one-time first-launch offer (`Library.offerVaultIfNeeded`, only when no notes folder
    is set and there's no `~/Obsidian Vault`) call `Library.useVault`: notes → `<vault>/Literature`,
    library.bib → `<vault>/library.bib` (an existing one is copied in).
17. **SQLite**: thin wrappers `DB` and `Stmt` over the system `libsqlite3` C API.

### Index schema

```sql
files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime REAL, size INTEGER,
      npages INTEGER,   -- -1 = couldn't open
      chars INTEGER)    -- total text length; < 50 shown as "no text"
folders(path TEXT PRIMARY KEY, name TEXT)   -- added folders; name = optional display name
excluded(path TEXT PRIMARY KEY)             -- files removed by hand; skipped on rescans
fts USING fts5(body, tokenize='unicode61 remove_diacritics 2')
notes USING fts5(quote, comment, kind UNINDEXED, page UNINDEXED, label UNINDEXED,
                 tokenize='unicode61 remove_diacritics 2')
      -- kind: h = highlight/note, s = "About this paper", o = a paragraph of a paper note (.md)
notefiles(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime REAL, pdf TEXT, key TEXT)
edits(path TEXT PRIMARY KEY, time REAL)      -- saves of highlights/notes made in PDF Search
      -- files also has `edited REAL`: newest annotation date in the PDF
      -- paper notes whose own text is indexed; pdf = the note's `pdf:` line as written
```

Note kinds in `notes`: `e` Essential highlight, `h` other highlight or note, `s` summary, `o` paper-note paragraph
(My Notes lists `e` first). `notes` rowids: `fileID * 10000 + n` for a PDF's annotations (deleted with the file, as a range),
`-(notefileID * 10000 + n)` for paper-note paragraphs. `PRAGMA user_version` is the index version:
on upgrading to 2, `setup()` zeroes every `files.mtime` so the next rescan re-reads all PDFs and fills `notes`.

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
- Highlighting has no undo (use Remove Highlight).
- Lookups need the internet; Crossref title matches can be the wrong paper, so the card always asks.
- Margin notes are listed in page order, not pinned next to their passage on screen.

## Ideas for extending (and where to put them)

- **Batch lookups**: run `Lookup` over all PDFs without details and offer one combined review list.
- **Undo/redo for highlights**: register add/remove with the window's `NSUndoManager` in
  `Viewer.addHighlight` / `removeHighlight`.
- **OCR for scans**: in `Library.extract`, if a page's text is empty, render the page
  (`PDFPage.thumbnail(of:for:)`) and run Vision's `VNRecognizeTextRequest`.
- **Live updates**: watch added folders with FSEvents and call `index(...)` for changed paths.
- **OR / NOT / NEAR**: extend `Library.parse` to pass these through, and keep `terms` only for
  positive terms.
- **Sort / filter results**: by name, date, number of hits; by year.
- **Quick Look** (spacebar) on a result, **export results** as a list or a reading list in Markdown.
