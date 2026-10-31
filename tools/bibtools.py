"""Shared helpers for PDF Search's one-time import scripts.

The citation-key rule here MUST match CiteKey in PDFSearch.swift:
    last name + year + first meaningful title word, lowercase ASCII
    e.g. Cascone (2000) "The Aesthetics of Failure" -> cascone2000aesthetics
    clashes get b, c, ...; missing year -> nd; missing name -> anon
"""
import re
import unicodedata

STOPWORDS = set("""a an the on of in for and to toward towards with from at by into about via is are as what how why
when do does can some its it this that these those or vs versus le la les el los las der die das den ein eine und von zu
im di da de du des""".split())

_REPL = {"ß": "ss", "æ": "ae", "Æ": "ae", "œ": "oe", "ø": "o", "Ø": "o", "ł": "l", "Ł": "l", "đ": "d", "þ": "th"}


def ascii_fold(s: str) -> str:
    for a, b in _REPL.items():
        s = s.replace(a, b)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    return s.lower()


def last_name(person: str) -> str:
    person = person.strip().strip("{}")
    if "," in person:
        return person.split(",")[0].strip()
    parts = person.split()
    return parts[-1] if parts else person


def make_key(last: str, year: str, title: str, existing: set) -> str:
    name = re.sub(r"[^a-z0-9]", "", ascii_fold(last))
    m = re.search(r"\d{4}", year or "")
    y = m.group(0) if m else "nd"
    words = [w for w in re.split(r"[\W_]+", ascii_fold(title or "")) if w]
    word = next((w for w in words if w not in STOPWORDS), "")
    base = (name or "anon") + y + word
    if base not in existing:
        return base
    for suffix in "bcdefghijklmnopqrstuvwxyz":
        if base + suffix not in existing:
            return base + suffix
    raise RuntimeError("too many clashes for " + base)


ORDER = ["author", "editor", "title", "booktitle", "journal", "journaltitle", "chapter", "edition", "volume", "number",
         "series", "pages", "publisher", "school", "institution", "address", "year", "month", "date", "doi", "isbn",
         "issn", "url", "urldate", "note"]
VERBATIM = {"url", "doi", "file"}


def escape(v: str) -> str:
    out, prev = [], " "
    for ch in v:
        if ch in "&%#_" and prev != "\\":
            out.append("\\")
        out.append(ch)
        prev = ch
    return "".join(out).replace("–", "--").replace("—", "---")


def format_entry(typ: str, key: str, fields: dict, file: str = None) -> str:
    keys = [k for k in ORDER if k in fields] + sorted(k for k in fields if k not in ORDER and k != "file")
    lines = []
    for k in keys:
        v = (fields.get(k) or "").strip()
        if not v:
            continue
        v = re.sub(r"\s+", " ", v)
        lines.append(f"  {k} = {{{v if k in VERBATIM else escape(v)}}}")
    if file:
        lines.append(f"  file = {{{file}}}")
    return f"@{typ}{{{key},\n" + ",\n".join(lines) + "\n}\n"


if __name__ == "__main__":
    ex = set()
    for last, y, t in [("Cascone", "2000", "The Aesthetics of Failure"), ("Cascone", "2000", "The Aesthetics of Failure"),
                       ("Müller", "", "Über die Klänge"), ("Šiška", "2019-04", "On the Glitch"), ("", "1999", "A")]:
        k = make_key(last, y, t, ex)
        ex.add(k)
        print(k)
    print(format_entry("book", "k", {"title": "A & B – C_d", "author": "Smith, J", "url": "http://x.org/a_b"}, "/p/k.pdf"))
