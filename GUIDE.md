# PDF Search: visual quick start

What PDF Search does, step by step. (To install it, see the [TL;DR in the README](README.md#tldr-get-it-running-in-5-minutes).)

---

## 1. Find anything in any PDF

![Searching across all PDFs: results on the left with thumbnails and highlighted snippets; the open PDF with every match marked in orange](docs/guide/01-search.jpg)

- **Type in the search box** (top left). Every PDF in your Papers folder is searched as you type. A PDF must contain **all your words**, anywhere in it (capitals don't matter): `accessible design`.
- For an **exact phrase**, use quotes: `"accessible instrument design"`.
- **Results** show each paper's first page (a book shows its cover), title, author and year, its citation key (`@davanzo2020dimension`), and the matching text.
- **Click a result** to open it. Your search words are marked in **orange**. The arrows at the top (**‹ 1 of 109 ›**, or ⌘G) jump from match to match.
- **Search in** narrows the search: one folder, **My Notes** (only what you've written), **Recently Edited** (papers you've worked on) or **Recently Added**.

---

## 2. Highlight and write notes in the margin

![A PDF with pink Essential and yellow Interesting highlights; on the right, the Highlights & Notes column with a note card for each highlight](docs/guide/02-read-notes.jpg)

- **Select a passage and press H.** It turns **yellow** (Interesting), and a note card opens in the column on the right. Type your thought; it saves itself.
- **Tick ☐ Essential** on a card for the few passages that matter most. They turn **pink**.
- **Add to a highlight:** select text that touches it and press H. It grows, and keeps its note.
- **Changed your mind?** Click **Remove** on a card, then **⌘Z** to undo or **⇧⌘Z** to redo.
- **Click a card** to jump to its passage in the PDF (it's briefly outlined).
- **About this paper** (top of the column) is for notes on the whole paper.
- Add **#tags** to a note (e.g. `#improvisation`) to group ideas across papers. Click a tag to see every note with it.
- Everything is saved **inside the PDF**, as standard PDF comments, so Preview and other apps see it too.

---

## 3. Search only what you've written

![Search in My Notes: each result is one of your notes, with Essential ones first and marked with a star; clicking one opens its page](docs/guide/03-my-notes.jpg)

- **Search in ▸ My Notes** (⇧⌘F) searches only your highlights, notes and summaries.
- Each result is **one note**: the passage, your comment, and its page. **Essential** notes come first (★).
- Click a result and the PDF opens at that passage.
- Right-click a note ▸ **Copy Quote with Citation** gives you `“the passage” [@key, p. 2]`, ready to paste into a draft.

---

## 4. Every annotated paper gets a note in Obsidian

![The paper's note in Obsidian: title, citation key, an Essential section with quotes, page links and the note, then Interesting](docs/guide/06-obsidian.jpg)

- For every paper you annotate, PDF Search keeps a Markdown note, `@key.md`: **Essential** passages first, then **Interesting**, each with your notes.
- Each quote has a **p. 2** link that opens the PDF at that page, and a citation `[@key, p. 2]` you can paste into your writing.
- **Open in Obsidian** (toolbar, ⌥⌘O) jumps to a paper's note. Write your own thoughts under **Notes**, and PDF Search never changes them.
- **No Obsidian?** The notes are plain Markdown in `~/Papers/Notes`; any notes app or text editor can open them.

---

## 5. Cite it

![The Copy Citation menu: [@key] for Obsidian/Pandoc, [[@key]] for a link to the paper's note, \cite{key} for LaTeX/Overleaf, or the key](docs/guide/05-copy-citation.jpg)

**Copy Citation** (toolbar) copies, then you paste:
- `[@key]`: a citation in Obsidian or any Markdown + Pandoc document
- `[[@key]]`: a link to the paper's note in Obsidian (e.g. in a project note)
- `\cite{key}`: a citation in LaTeX or Overleaf

All of them use one plain bibliography file, `library.bib`.

---

## 6. Add pages from a paper book

Photograph the pages you've marked, and they become part of your library. Nothing leaves your Mac except the book lookup.

![A photographed book page in PDF Search: the yellow streak in the margin beside the underlined lines has become a highlight, with a note card on the right and the book's cover in the results](docs/guide/07-book-pages.jpg)

1. **Copy your photos** into the `Book Photos` folder inside your Papers folder (**File ▸ Open Book Photos Folder**).
2. **That's all.** PDF Search takes them within about 10 seconds if it's open, or when you next open it, and then shows you the book.

**The rules:**
- **A new book needs a photo of its copyright page.** That's how PDF Search finds the book, from its ISBN. Later batches usually don't need it, if the pages show the book's title at the top.
- **One book at a time.** To mix books, start each book's photos with its copyright page.

**What you get:**
- One searchable PDF for each book, with the pages in order, and new photos join it. The book shows its real cover in your results.
- Citations use the page numbers printed in the book. If a number can't be read, it's cited as `p. ?`. Fix it with **File ▸ Set Printed Page Number…**
- **A yellow streak in the margin** beside underlined lines becomes a highlight. Underlines with no yellow are left alone.
- The text beside each highlight was read from the photo, so a word can be wrong. Select it to copy it, or click **Edit** on the card to correct it. Search and your paper notes use your correction.

**Where your photos go:** filed ones move to `Book Photos/Done`, and any it couldn't file move to `Book Photos/Not Filed`. Your originals are never deleted. To file those, add a photo of the copyright page and move them all back into `Book Photos`.

---

## 7. Forgot how it works?

<img src="docs/guide/04-readme.jpg" width="420" alt="The README card inside the app: numbered steps explaining the workflow">

Click **README** at the bottom of the results list (or **Help ▸ PDF Search README**, ⌘?) for this one-page reminder, inside the app.

---

**Adding papers:** drag a PDF onto the window. PDF Search finds its DOI, ISBN or title, fetches the citation details, shows them on a card to check, then files the PDF as `Papers/Library/<key>.pdf`.

**Adding lots of papers:** drag a folder, or more than three PDFs. The details are found in the background, with no cards, and a folder's PDFs stay where they are. If a PDF's details can't be confirmed, it stays searchable; right-click it ▸ **Look Up Citation Details…**

**What's new in your library?** **Search in ▸ Recently Added** (⇧⌘D) lists it, newest first.

More detail: the [README](README.md) and [Developer Notes](dist/Developer%20Notes.md).
