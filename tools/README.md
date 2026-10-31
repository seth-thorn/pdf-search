# Moving from Zotero

`import_zotero.py` copies a Zotero library into PDF Search's layout, once:

- every item becomes an entry in `library.bib` with a **new** citation key (last name + year + title word),
- every PDF is **copied** to `~/Papers/Library/<key>.pdf` (Zotero is never changed),
- highlights, underlines and sticky notes you made in **Zotero's own PDF reader** (which Zotero keeps in its
  database, not in the file) are written into the copied PDFs as standard PDF annotations,
- items without a PDF (books, chapters…) still get a `library.bib` entry.

Zotero's separate "note" documents are not imported.

## Run it

Quit Zotero first. You need Python 3 and PyMuPDF (`pip3 install pymupdf`, used to write the highlights).

```
python3 tools/import_zotero.py ~/Zotero ~/Papers/Library ~/Papers/library.bib ~/Papers/Library --dry-run
```

`--dry-run` only reports what would happen. Run it again without `--dry-run` to do it. Arguments:

1. your Zotero data folder (contains `zotero.sqlite` and `storage/`)
2. where to copy the PDFs
3. where to write `library.bib` (if you use Obsidian: `~/Obsidian\ Vault/library.bib`)
4. the PDF folder again, as written into `library.bib` (normally the same as 2)

It can be stopped and re-run: finished PDFs are skipped. An existing `library.bib` is kept as `library.bib.before-import`.

`bibtools.py` holds the citation-key rule and BibTeX writer shared with the app; keep them in sync with
`CiteKey` / `BibWriter` in `PDFSearch.swift`.
