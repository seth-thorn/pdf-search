# PDF Search

A small, native Mac app for reading and citing research PDFs: full-text search across all of them, notes in the margins, and a plain BibTeX bibliography. A lightweight alternative to DEVONthink and Zotero for people who want one simple tool.

<img src="dist/icon.png" width="96" align="right" alt="">

- **Add papers and books in one step.** Drop a PDF on the window: PDF Search finds its DOI (or arXiv ID, ISBN, or title), fetches the citation details from doi.org / Crossref / Open Library, shows them on a card to check, then files the PDF as `~/Papers/Library/<key>.pdf` and adds it to `library.bib`. Books without a PDF: type the ISBN.
- **Search everything.** Every word of every PDF in your `~/Papers` folder, as you type, with snippets and page counts. Prefix matching, `"exact phrases"`, and accents/case ignored. Search one folder or all of them.
- **Read.** Click a result and the PDF opens at the first match, with every match marked. ⌘G steps through them, and ⌘F finds within the open PDF.
- **Write in the margins.** Select a passage and press **H**. It's highlighted, and a note box opens in the notes column beside the PDF. Every highlight has a note box, which saves as you type. Each highlight has a clear Remove button. An **About this paper** box holds notes on the whole paper. Notes are saved *inside the PDF* as standard comments, so Preview, Acrobat and other apps see them too, and they're searchable.
- **Cite.** PDFs are matched to entries in a plain `library.bib`, so results show real titles and authors. ⇧⌘C copies `[@cascone2000aesthetics]` (Markdown/Pandoc), and ⌥⇧⌘C copies `\cite{cascone2000aesthetics}` (LaTeX/Overleaf). Books you don't have as PDFs live in the same bibliography.
- **Collections.** A reading list for each thing you're writing, kept as a plain Markdown note (`- [[@key]] Author (Year) Title`). Add papers with one click, browse a collection like a folder, and turn it into a `.bib` file for Overleaf or Pandoc.
- **Notes that turn into writing.** For every PDF you annotate, PDF Search keeps a Markdown note (`@key.md`) with each quote, a page-cited reference (`[@key, p. 12]`), a link back to that page, and your note. Write your own thoughts below; they're never overwritten.

**Obsidian is optional.** If you have a folder called `Obsidian Vault` in your home folder, `library.bib`, the paper notes (`Literature/`) and collections (`Collections/`) go there. Otherwise they go in `~/Papers` (`library.bib`, `Notes/`, `Collections/`). You can open them with any text editor or notes app, and change all of this in **Settings (⌘,)**.

It's one Swift file (SwiftUI + PDFKit + SQLite full-text search) with no dependencies. Requires macOS 13 or later.

## Build it

1. Install Apple's command line tools (once). In Terminal:
   ```
   xcode-select --install
   ```
2. Get the code: either `git clone https://github.com/seth-thorn/pdf-search.git`, or click **Code → Download ZIP** above and unzip it.
3. Build it. In Terminal, go into the folder and run the build script:
   ```
   cd pdf-search          # or: cd ~/Downloads/pdf-search-main
   bash build.sh
   ```
   The app is built into `/Applications/PDF Search.app` (or `~/Applications` if you can't write to `/Applications`). The build also prints a short self-test.

Because you build it yourself, macOS doesn't show the "unverified developer" warning.

## Set up your papers

```
~/Papers/
├── Library/        ← your own papers, ideally named by citation key (cascone2000aesthetics.pdf)
└── …               ← any other collections (conference proceedings, course readings…)
```

PDF Search indexes `~/Papers` automatically. Each folder inside it can be searched on its own with the "Search in" menu. You can also drag any other folder into the window.

**Citation keys** are last name + year + the first meaningful word of the title, all lowercase: `cascone2000aesthetics`, `collins2006handmade`. If two items would get the same key, the second gets a letter (`…b`).

**Adding papers:** drag a PDF onto the window (or **+ → Add Paper**, ⌘O), check the card, press **Add to Library**. **+ → Add Book or Chapter** (⇧⌘O) looks up an ISBN. Right-click a PDF without details → **Look Up Citation Details…**. To make a folder searchable without adding it to your bibliography: **+ → Add Folder to Search…**.

**Coming from Zotero?** [`tools/import_zotero.py`](tools/) copies your Zotero library into `~/Papers/Library` and writes `library.bib` with fresh keys. It also writes the highlights you made in Zotero's reader into the PDFs. Zotero itself is only read, never changed. See [tools/README.md](tools/README.md).

## Everyday use

| Keys | Action |
|---|---|
| type in the search box | search everything (or the folder chosen in "Search in") |
| ⌘F | find inside the open PDF |
| ⌘G / ⇧⌘G | next / previous match |
| H | highlight the selected text (a note box opens beside it), also ⌃⌘H |
| ⇧⌘C / ⌥⇧⌘C | copy `[@key]` / `\cite{key}` for the open paper |
| ⌘O / ⇧⌘O | add a paper (PDF) / add a book or chapter (ISBN) |
| ⌘R | rescan folders |
| ⌘0 | zoom to fit |
| ⌘, | settings: papers folder, `library.bib` location, notes and collections folders |

More detail is in **[PDF Search Guide.pdf](dist/PDF%20Search%20Guide.pdf)**. To try it quickly, drag the `test-pdfs` folder in and search for `glitch`.

## Writing with it

- **Markdown (Obsidian, iA Writer, any editor) + Pandoc:** cite with `[@key]`, then export with `pandoc paper.md --citeproc --bibliography ~/Papers/library.bib -o paper.pdf` (or `.docx`). Add `--csl apa.csl` for a specific style.
- **LaTeX / Overleaf:** upload `library.bib` and cite with `\cite{key}`.
- A collection's ••• menu has **Make Bibliography (.bib)**: just that project's entries, ready for Overleaf.
- The `@key.md` paper notes already contain your quotes with page-cited references, ready to paste into a draft.

## Repository layout

| Path | What |
|---|---|
| `PDFSearch.swift` | the whole app |
| `Info.plist`, `AppIcon.icns` | app bundle metadata and icon |
| `build.sh`, `Build PDF Search.command` | build and install the app |
| `make-package.sh` | makes a shareable `.dmg` (universal app + guide + source) on your Desktop |
| `tools/` | one-time Zotero import |
| `dist/` | the guide PDF, developer notes and read-me used by the `.dmg` |
| `test-pdfs/` | three tiny PDFs for testing |

How it works inside, and ideas for extending it: **[Developer Notes](dist/Developer%20Notes.md)**.

## Credits

Made by Seth Thorn, built with Claude. MIT licensed (see [LICENSE](LICENSE)).
