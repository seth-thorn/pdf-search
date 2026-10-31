# PDF Search

A small, native Mac app for searching the full text of all your PDFs at once. It's a lightweight alternative to DEVONthink for one job: find every PDF (and page) that mentions something, then jump straight to it.

<img src="dist/icon.png" width="96" align="right" alt="">

- **Drag in folders of PDFs** (a Zotero library, course readings, a collection of papers…). They're indexed once, and then searches are instant.
- **Type words** and see matching PDFs as you type, with snippets and page counts. Prefix matching, `"exact phrases"`, and accents/case ignored.
- **Search in one folder or all of them.**
- **Click a result** and the PDF opens at the first match with every match marked. Step through them with ⌘G.
- **⌘F** finds inside the open PDF.
- **Highlight** text like in Preview. Highlights are saved into the PDF.
- Your PDFs stay where they are. The app only stores an index of their text.

It's one Swift file (SwiftUI + PDFKit + SQLite full-text search) with no dependencies. Requires macOS 13 or later, on Apple Silicon or Intel.

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
   The app is built into `/Applications/PDF Search.app` (or `~/Applications` if you can't write to `/Applications`). Open it from there.

Because you build it yourself, macOS doesn't show the "unverified developer" warning.
(`Build PDF Search.command` does the same thing with a log file and can be double-clicked, but macOS may block double-clicking scripts that came from a download, so `bash build.sh` is the reliable way.)

## Use it

See **[PDF Search Guide.pdf](dist/PDF%20Search%20Guide.pdf)** for everything: adding folders, search syntax, ⌘F, highlighting and keyboard shortcuts.
To try it quickly, drag the `test-pdfs` folder in and search for `glitch`.

## Repository layout

| Path | What |
|---|---|
| `PDFSearch.swift` | the whole app |
| `Info.plist`, `AppIcon.icns` | app bundle metadata and icon |
| `build.sh`, `Build PDF Search.command` | build and install the app |
| `make-package.sh` | makes a shareable `.dmg` (universal app + guide + source) on your Desktop |
| `dist/` | the guide PDF, developer notes and read-me used by the `.dmg` |
| `test-pdfs/` | three tiny PDFs for testing |

How it works inside, and ideas for extending it: **[Developer Notes](dist/Developer%20Notes.md)**.

## Credits

Made by Seth Thorn, built with Claude. MIT licensed (see [LICENSE](LICENSE)).
