#!/usr/bin/env python3
"""One-time import: Zotero library -> ~/Papers/Library/<key>.pdf + library.bib (for PDF Search).

Reads a COPY of zotero.sqlite (Zotero is never modified). Every item gets a fresh citation key
(last name + year + title word). PDFs are copied (not moved), so Zotero keeps working until you delete it.

usage: import_zotero.py ZOTERO_DIR LIBRARY_DIR BIB_PATH MAC_LIBRARY_DIR [--dry-run]
  ZOTERO_DIR       folder containing zotero.sqlite and storage/ (as seen by this script)
  LIBRARY_DIR      where to copy PDFs (as seen by this script)
  BIB_PATH         library.bib to write (as seen by this script)
  MAC_LIBRARY_DIR  the same library folder as the Mac sees it (written into the bib's file fields)
"""
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bibtools import format_entry, last_name, make_key  # noqa: E402

TYPE_MAP = {
    "journalArticle": "article", "magazineArticle": "article", "newspaperArticle": "article",
    "conferencePaper": "inproceedings", "book": "book", "bookSection": "incollection",
    "thesis": "phdthesis", "report": "techreport", "manuscript": "unpublished",
}


def table(cur, name):
    """Prefer Zotero's *Combined tables (they include custom types/fields) when present."""
    combined = name + "Combined"
    have = {r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
    return combined if combined in have else name


def transfer_annotations(cur, att_to_dst, dry):
    """Copy Zotero reader annotations (highlight=1, note=2, underline=5) into the copied PDFs."""
    stats = Counter()
    if not cur.execute("SELECT 1 FROM sqlite_master WHERE name='itemAnnotations'").fetchone():
        return stats
    cols = {r[1] for r in cur.execute("PRAGMA table_info(itemAnnotations)")}
    ext = "AND isExternal = 0" if "isExternal" in cols else ""
    by_att = defaultdict(list)
    for row in cur.execute(f"""SELECT parentItemID, type, authorName, comment, color, position FROM itemAnnotations
                               WHERE 1=1 {ext} ORDER BY parentItemID, sortIndex"""):
        by_att[row[0]].append(row)
    if dry:
        stats["to copy (for PDFs copied in this run)"] = sum(len(v) for a, v in by_att.items())
        return stats
    import pymupdf
    for att, anns in by_att.items():
        dst = att_to_dst.get(att)
        if not dst:
            continue
        doc = pymupdf.open(dst)
        changed = False
        for _, typ, author, comment, color, pos in anns:
            try:
                p = json.loads(pos)
                page = doc[p["pageIndex"]]
            except Exception:
                stats["skipped (bad position)"] += 1
                continue
            m = page.transformation_matrix
            rects = [(pymupdf.Rect(r) * m).normalize() for r in p.get("rects", [])]
            rects = [r for r in rects if not r.is_empty]
            try:
                rgb = tuple(int((color or "#ffd400")[i:i + 2], 16) / 255 for i in (1, 3, 5))
            except ValueError:
                rgb = (1, 0.83, 0)
            if typ in (1, 5) and rects:
                quads = [r.quad for r in rects]
                a = page.add_highlight_annot(quads) if typ == 1 else page.add_underline_annot(quads)
            elif typ == 2 and rects:
                a = page.add_text_annot(rects[0].tl, comment or "")
            else:
                stats["skipped (image/ink/text box)"] += 1
                continue
            a.set_colors(stroke=rgb)
            a.set_info(content=comment or "", title=author or "")
            a.update()
            changed = True
            stats["copied"] += 1
        if changed:
            if doc.can_save_incrementally():
                doc.saveIncr()
            else:
                tmp = dst + ".tmp"
                doc.save(tmp, garbage=1)
                doc.close()
                os.replace(tmp, dst)
                continue
        doc.close()
    return stats


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    zdir, libdir, bibpath, maclib = args
    tmp = tempfile.mkdtemp()
    db = os.path.join(tmp, "zotero.sqlite")
    shutil.copy2(os.path.join(zdir, "zotero.sqlite"), db)
    for extra in ("-wal", "-shm"):   # include changes Zotero hasn't merged into the main file yet
        if os.path.exists(os.path.join(zdir, "zotero.sqlite" + extra)):
            shutil.copy2(os.path.join(zdir, "zotero.sqlite" + extra), db + extra)
    con = sqlite3.connect(db)
    cur = con.cursor()
    T_types, T_fields, T_ctypes = table(cur, "itemTypes"), table(cur, "fields"), table(cur, "creatorTypes")

    deleted = {r[0] for r in cur.execute("SELECT itemID FROM deletedItems")} if \
        cur.execute("SELECT 1 FROM sqlite_master WHERE name='deletedItems'").fetchone() else set()
    items = cur.execute(f"""SELECT i.itemID, i.key, t.typeName, i.dateAdded FROM items i
                            JOIN {T_types} t ON t.itemTypeID = i.itemTypeID
                            ORDER BY i.dateAdded, i.itemID""").fetchall()
    fields = defaultdict(dict)
    for item_id, fname, value in cur.execute(f"""SELECT d.itemID, f.fieldName, v.value FROM itemData d
                                                 JOIN {T_fields} f ON f.fieldID = d.fieldID
                                                 JOIN itemDataValues v ON v.valueID = d.valueID"""):
        fields[item_id][fname] = value
    creators = defaultdict(list)
    for item_id, first, last, mode, ctype in cur.execute(f"""SELECT ic.itemID, c.firstName, c.lastName, c.fieldMode, ct.creatorType
                                                             FROM itemCreators ic JOIN creators c ON c.creatorID = ic.creatorID
                                                             JOIN {T_ctypes} ct ON ct.creatorTypeID = ic.creatorTypeID
                                                             ORDER BY ic.itemID, ic.orderIndex"""):
        name = "{" + (last or "") + "}" if mode == 1 else (f"{last}, {first}" if first else (last or ""))
        creators[item_id].append((ctype, name, last or ""))
    attachments = defaultdict(list)   # parent item -> [path on disk]
    standalone = []
    keys_by_id = {i[0]: i[1] for i in items}
    for item_id, parent, mode, ctype, path in cur.execute(
            "SELECT itemID, parentItemID, linkMode, contentType, path FROM itemAttachments"):
        if item_id in deleted or not path:
            continue
        if path.startswith("storage:"):
            disk = os.path.join(zdir, "storage", keys_by_id.get(item_id, ""), path[len("storage:"):])
        elif path.startswith("attachments:"):
            disk = None   # relative to a base directory we don't know; reported below
        else:
            disk = path
        is_pdf = (ctype == "application/pdf") or (path.lower().endswith(".pdf"))
        if not is_pdf:
            continue
        if parent:
            attachments[parent].append((item_id, disk))
        else:
            standalone.append(disk)
    n_annot = cur.execute("SELECT count(*) FROM itemAnnotations").fetchone()[0] if \
        cur.execute("SELECT 1 FROM sqlite_master WHERE name='itemAnnotations'").fetchone() else 0

    os.makedirs(libdir, exist_ok=True)
    done_path = os.path.join(libdir, ".zotero-import-done.json")   # lets an interrupted run resume
    done = json.load(open(done_path)) if os.path.exists(done_path) else {}
    att_to_dst = {}
    entries, keys = [], set()
    stats = Counter()
    missing_files, unknown_paths = [], 0
    for item_id, zkey, typ, added in items:
        if item_id in deleted or typ in ("attachment", "note", "annotation"):
            continue
        f = fields[item_id]
        people = creators[item_id]
        authors = [n for t, n, _ in people if t == "author"]
        editors = [n for t, n, _ in people if t == "editor"]
        lead = (authors or editors or [n for _, n, _ in people] or [""])[0]
        year = f.get("date", "")
        key = make_key(last_name(lead), year, f.get("title", ""), keys)
        keys.add(key)
        btype = TYPE_MAP.get(typ, "misc")
        if typ == "thesis" and "master" in (f.get("thesisType", "") or "").lower():
            btype = "mastersthesis"
        b = {"title": f.get("title")}
        if authors:
            b["author"] = " and ".join(authors)
        if editors:
            b["editor"] = " and ".join(editors)
        m = re.search(r"\d{4}", year)
        if m:
            b["year"] = m.group(0)
        b["doi"] = f.get("DOI")
        b["url"] = f.get("url")
        b["pages"] = f.get("pages")
        b["volume"] = f.get("volume")
        b["number"] = f.get("issue") or f.get("reportNumber")
        b["publisher"] = f.get("publisher")
        b["address"] = f.get("place")
        b["isbn"] = f.get("ISBN")
        b["issn"] = f.get("ISSN")
        b["edition"] = f.get("edition")
        b["series"] = f.get("series")
        if btype == "article":
            b["journal"] = f.get("publicationTitle")
        elif btype == "inproceedings":
            b["booktitle"] = f.get("proceedingsTitle") or f.get("conferenceName") or f.get("publicationTitle")
        elif btype == "incollection":
            b["booktitle"] = f.get("bookTitle") or f.get("publicationTitle")
        elif btype in ("phdthesis", "mastersthesis"):
            b["school"] = f.get("university") or f.get("publisher")
            b.pop("publisher", None)
        elif btype == "techreport":
            b["institution"] = f.get("institution") or f.get("publisher")
            b.pop("publisher", None)
        elif btype == "misc":
            if f.get("websiteTitle") or f.get("blogTitle"):
                b["note"] = f.get("websiteTitle") or f.get("blogTitle")
            if f.get("accessDate"):
                b["urldate"] = f.get("accessDate")[:10]
        if b["url"] and btype in ("article", "inproceedings", "incollection", "book") and b.get("doi"):
            b.pop("url")   # keep entries tidy: DOI is enough
        b = {k: v for k, v in b.items() if v}

        file_field = None
        pdfs = [(a, p) for a, p in attachments.get(item_id, []) if p]
        unknown_paths += sum(1 for _, p in attachments.get(item_id, []) if p is None)
        for i, (att_id, src) in enumerate(pdfs):
            name = f"{key}.pdf" if i == 0 else f"{key}-{i + 1}.pdf"
            if not os.path.exists(src):
                missing_files.append(src)
                continue
            dst = os.path.join(libdir, name)
            if not dry and not (done.get(str(att_id)) == name and os.path.exists(dst)):
                shutil.copy2(src, dst)
                att_to_dst[att_id] = dst
            if i == 0:
                file_field = os.path.join(maclib, name)
            stats["pdfs copied"] += 1
        stats["with PDF" if file_field else "without PDF"] += 1
        stats[btype] += 1
        entries.append(format_entry(btype, key, b, file_field))

    for src in standalone:
        if src and os.path.exists(src):
            base = re.sub(r"[/:]", "-", os.path.basename(src))
            dst = os.path.join(libdir, base)
            if not dry and not os.path.exists(dst):
                shutil.copy2(src, dst)
            stats["standalone PDFs (no details)"] += 1

    # Zotero keeps highlights in its database, not in the PDF: write them into the copied PDFs
    ann_stats = transfer_annotations(cur, att_to_dst, dry)
    if not dry:
        for att_id, dst in att_to_dst.items():
            done[str(att_id)] = os.path.basename(dst)
        json.dump(done, open(done_path, "w"))

    header = ("% library.bib: your bibliography, written by PDF Search.\n"
              "% Imported from Zotero; every item has a new citation key (lastname + year + title word).\n"
              "% PDFs live in ~/Papers/Library/<key>.pdf. Keys never change once given.\n\n")
    if not dry:
        if os.path.exists(bibpath) and os.path.getsize(bibpath) > 0:
            shutil.copy2(bibpath, bibpath + ".before-import")
        with open(bibpath, "w", encoding="utf-8") as fh:
            fh.write(header + "\n".join(entries))
    print(f"items imported: {len(entries)}")
    for k, v in sorted(stats.items()):
        print(f"  {k}: {v}")
    if missing_files:
        print(f"  PDF attachments whose file is missing on disk: {len(missing_files)}")
    if unknown_paths:
        print(f"  linked PDFs with a relative 'attachments:' path (not copied): {unknown_paths}")
    print(f"annotations stored inside Zotero's database (not in the PDFs): {n_annot}")
    for k, v in sorted(ann_stats.items()):
        print(f"  annotations {k}: {v}")
    print("sample entries:\n" + "\n".join(entries[:3]))
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
