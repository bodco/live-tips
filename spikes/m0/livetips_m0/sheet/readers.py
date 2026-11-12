"""0.10.0 (Meeting Sheet, phase 2): readers of local files, shared by every AI route (the packed ways get text, never
bytes; before 0.10.0 a PDF reached the packed ways as UTF-8 garbage).

read(path) -> {"text", "kind", "chars", "pages"?, "slides"?, "sheets"?, "error"?, "unsupported"?}
  pdf   pdftotext when installed, else PDFKit through JavaScript for Automation (osascript, macOS), else a small
        pure-Python reader for simple PDFs (Flate streams, Tj/TJ text), else unsupported with the reason.
  pptx  slide order from ppt/presentation.xml (sldIdLst and its relationships, as the app's PptxOrder), hidden
        slides skipped, the speaker notes kept. Slide n is the position in the show, not the file number.
  xlsx  every sheet as tab-separated rows (shared strings, inline strings, numbers), stdlib only.
  docx  paragraphs and tables (word/document.xml), stdlib only; .doc/.rtf/.odt/.pages through textutil on a Mac.
  csv, md, txt, json, yaml, html (tags stripped): as text.
Nothing here talks to the network.
"""
import html as _html
import os
import re
import shutil
import subprocess
import zipfile
import zlib
from pathlib import Path
from typing import Dict, List, Optional
from xml.etree import ElementTree as ET

TEXT_EXT = (".md", ".txt", ".csv", ".tsv", ".json", ".yaml", ".yml", ".log", ".markdown")
HTML_EXT = (".html", ".htm")
TEXTUTIL_EXT = (".doc", ".rtf", ".odt", ".pages")
SUPPORTED = TEXT_EXT + HTML_EXT + TEXTUTIL_EXT + (".pdf", ".pptx", ".xlsx", ".docx")

NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
    "s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
}


def kind_of(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return ext[1:] if ext else ""


def supported(path: str) -> bool:
    return path.lower().endswith(SUPPORTED)


def _done(text: str, kind: str, **extra) -> dict:
    text = text or ""
    out = {"text": text, "kind": kind, "chars": len(text)}
    out.update(extra)
    return out


def _fail(kind: str, reason: str, unsupported: bool = False) -> dict:
    out = {"text": "", "kind": kind, "chars": 0, "error": reason}
    if unsupported:
        out["unsupported"] = True
    return out


def read(path: str) -> dict:
    p = os.path.expanduser(path)
    k = kind_of(p)
    if not os.path.exists(p):
        return _fail(k, "file not found")
    if os.path.isdir(p):
        return _fail(k, "a folder, not a file", True)
    if not os.access(p, os.R_OK):
        return _fail(k, "no permission to read the file")
    try:
        low = p.lower()
        if low.endswith(TEXT_EXT):
            return _done(Path(p).read_text(encoding="utf-8", errors="replace"), k)
        if low.endswith(HTML_EXT):
            return _done(html_text(Path(p).read_text(encoding="utf-8", errors="replace")), k)
        if low.endswith(".pdf"):
            return read_pdf(p)
        if low.endswith(".pptx"):
            return read_pptx(p)
        if low.endswith(".xlsx"):
            return read_xlsx(p)
        if low.endswith(".docx"):
            return read_docx(p)
        if low.endswith(TEXTUTIL_EXT):
            return read_textutil(p)
    except zipfile.BadZipFile:
        return _fail(k, "the file is damaged (not a valid Office file)")
    except PermissionError:
        return _fail(k, "no permission to read the file")
    except Exception as e:  # noqa: BLE001  one bad file never stops the others
        return _fail(k, f"cannot read: {type(e).__name__}")
    return _fail(k, f"{k or 'this'} files are not read (supported: pdf, pptx, xlsx, docx, csv, md, txt)", True)


def html_text(t: str) -> str:
    t = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", t)
    t = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>", "\n", t)
    t = re.sub(r"<[^>]+>", " ", t)
    t = _html.unescape(t)
    t = re.sub(r"[ \t\r\f\v]+", " ", t)
    return re.sub(r"\n\s*\n+", "\n\n", t).strip()


# ---------------------------------------------------------------- PDF

def read_pdf(p: str) -> dict:
    tool = shutil.which("pdftotext") or next((x for x in ("/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext")
                                              if os.path.exists(x)), None)
    if tool:
        try:
            r = subprocess.run([tool, "-layout", "-enc", "UTF-8", p, "-"], capture_output=True, timeout=120)
            if r.returncode == 0:
                text = r.stdout.decode("utf-8", "replace")
                pages = text.count("\f") + (1 if text and not text.endswith("\f") else 0)
                if text.strip():
                    return _done(_pages_marked(text.split("\f")), "pdf", pages=pages, reader="pdftotext")
        except (OSError, subprocess.SubprocessError):
            pass
    text = _pdfkit(p)
    if text is not None and text.strip():
        parts = text.split("\f")
        return _done(_pages_marked(parts), "pdf", pages=len(parts), reader="pdfkit")
    try:
        parts = pdf_pages_simple(Path(p).read_bytes())
    except Exception:  # noqa: BLE001
        parts = []
    if any(x.strip() for x in parts):
        return _done(_pages_marked(parts), "pdf", pages=len(parts), reader="simple")
    return _fail("pdf", "no text layer could be read (a scanned PDF, or no PDF reader on this Mac)", True)


def _pages_marked(parts: List[str]) -> str:
    """Page marks let a fact point to its page (locator.page)."""
    out = []
    for i, t in enumerate(parts):
        if t.strip():
            out.append(f"[page {i + 1}]\n{t.strip()}")
    return "\n\n".join(out)


JXA = """ObjC.import('PDFKit');
function run(argv) {
  var d = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!d || d.isNil()) return '';
  var out = [];
  for (var i = 0; i < d.pageCount; i++) { var s = d.pageAtIndex(i).string; out.push(s && !s.isNil() ? s.js : ''); }
  return out.join('\\f');
}"""


def _pdfkit(p: str) -> Optional[str]:
    if not os.path.exists("/usr/bin/osascript"):
        return None
    try:
        r = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", JXA, p], capture_output=True, timeout=120)
        return r.stdout.decode("utf-8", "replace").rstrip("\n") if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


_STREAM = re.compile(rb"stream\r?\n(.*?)\r?\nendstream", re.S)


def _pdf_string(s: bytes) -> str:
    out, i = bytearray(), 0
    esc = {b"n": b"\n", b"r": b"\r", b"t": b"\t", b"b": b"\b", b"f": b"\f", b"(": b"(", b")": b")", b"\\": b"\\"}
    while i < len(s):
        c = s[i:i + 1]
        if c == b"\\" and i + 1 < len(s):
            n = s[i + 1:i + 2]
            if n in esc:
                out += esc[n]; i += 2; continue
            m = re.match(rb"[0-7]{1,3}", s[i + 1:i + 4])
            if m:
                out.append(int(m.group(0), 8) & 0xFF); i += 1 + len(m.group(0)); continue
            i += 2; continue
        out += c; i += 1
    b = bytes(out)
    if b.startswith(b"\xfe\xff"):
        return b[2:].decode("utf-16-be", "replace")
    return b.decode("latin-1")


def _content_text(data: bytes) -> str:
    """Text operators of one content stream: (..) Tj, [..] TJ, ' and \"; T* / Td / TD / ET start a new line."""
    out: List[str] = []
    for m in re.finditer(rb"\((?:\\.|[^\\)])*\)\s*(?:Tj|'|\")|\[(?:\\.|[^\]])*\]\s*TJ|T\*|ET|-?\d*\.?\d+\s+-?\d*\.?\d+\s+T[dD]", data, re.S):
        tok = m.group(0)
        if tok.endswith(b"TJ"):
            out.append("".join(_pdf_string(x[1:-1]) for x in re.findall(rb"\((?:\\.|[^\\)])*\)", tok)))
        elif tok.endswith((b"Tj", b"'", b'"')):
            out.append(_pdf_string(re.match(rb"\(((?:\\.|[^\\)])*)\)", tok).group(1)))
        else:
            out.append("\n")
    text = "".join(x if x == "\n" else x + "" for x in out)
    return re.sub(r"\n\s*\n+", "\n", text).strip()


def pdf_pages_simple(raw: bytes) -> List[str]:
    """A last resort without any PDF tool: the text of Flate or plain content streams, in file order, one entry per
    stream that has text operators. Good for simple generated PDFs; a scanned or CID-font PDF gives nothing."""
    pages = []
    for m in _STREAM.finditer(raw):
        data = m.group(1)
        head = raw[max(0, m.start() - 300):m.start()]
        if b"/FlateDecode" in head:
            try:
                data = zlib.decompress(data)
            except zlib.error:
                continue
        elif b"/Filter" in head:
            continue
        if b"Tj" in data or b"TJ" in data:
            t = _content_text(data)
            if t:
                pages.append(t)
    return pages


# ---------------------------------------------------------------- Office (zip + XML)

def _xml(z: zipfile.ZipFile, name: str) -> Optional[ET.Element]:
    try:
        return ET.fromstring(z.read(name))
    except KeyError:
        return None


def _rels(z: zipfile.ZipFile, name: str) -> Dict[str, str]:
    d, f = os.path.split(name)
    root = _xml(z, f"{d}/_rels/{f}.rels")
    out = {}
    if root is None:
        return out
    for r in root.findall("rel:Relationship", NS):
        tgt = r.get("Target", "")
        if not tgt.startswith("/"):
            tgt = os.path.normpath(os.path.join(d, tgt)).replace("\\", "/")
        else:
            tgt = tgt.lstrip("/")
        out[r.get("Id", "")] = tgt
    return out


def _texts(el: Optional[ET.Element], para_tag: str, text_tag: str) -> List[str]:
    if el is None:
        return []
    out = []
    for para in el.iter(para_tag):
        t = "".join(x.text or "" for x in para.iter(text_tag)).strip()
        if t:
            out.append(t)
    return out


def pptx_order(z: zipfile.ZipFile) -> List[str]:
    """The slide parts in show order: presentation.xml sldIdLst through its relationships (the app's PptxOrder).
    A deck without a readable list falls back to the file numbers."""
    pres = _xml(z, "ppt/presentation.xml")
    rels = _rels(z, "ppt/presentation.xml")
    order = []
    if pres is not None:
        lst = pres.find("p:sldIdLst", NS)
        for s in (lst if lst is not None else []):
            rid = s.get("{%s}id" % NS["r"])
            if rid in rels and rels[rid] in z.namelist():
                order.append(rels[rid])
    if not order:
        names = [n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)]
        order = sorted(names, key=lambda n: int(re.findall(r"\d+", n)[-1]))
    return order


def read_pptx(p: str) -> dict:
    with zipfile.ZipFile(p) as z:
        slides, n = [], 0
        hidden = 0
        for part in pptx_order(z):
            root = _xml(z, part)
            if root is None:
                continue
            if root.get("show") in ("0", "false"):
                hidden += 1
                continue
            n += 1
            paras = _texts(root, "{%s}p" % NS["a"], "{%s}t" % NS["a"])
            title = ""
            for sp in root.iter("{%s}sp" % NS["p"]):
                ph = sp.find(".//p:nvPr/p:ph", NS)
                if ph is not None and ph.get("type") in ("title", "ctrTitle"):
                    title = " ".join(_texts(sp, "{%s}p" % NS["a"], "{%s}t" % NS["a"]))
                    break
            if not title and paras:
                title = paras[0]
            notes = ""
            for tgt in _rels(z, part).values():
                if "notesSlide" in tgt:
                    nroot = _xml(z, tgt)
                    body = []
                    if nroot is not None:
                        for sp in nroot.iter("{%s}sp" % NS["p"]):
                            ph = sp.find(".//p:nvPr/p:ph", NS)
                            if ph is not None and ph.get("type") == "body":
                                body += _texts(sp, "{%s}p" % NS["a"], "{%s}t" % NS["a"])
                    notes = "\n".join(body)
            body_text = "\n".join(x for x in paras if x != title)
            slides.append({"n": n, "title": title, "text": body_text, "notes": notes, "part": part})
    lines = []
    for s in slides:
        lines.append(f"[slide {s['n']}] {s['title']}\n{s['text']}".rstrip()
                     + (f"\nSpeaker notes: {s['notes']}" if s["notes"] else ""))
    return _done("\n\n".join(lines), "pptx", slides=slides, hidden_skipped=hidden)


def _col_index(ref: str) -> int:
    n = 0
    for ch in re.match(r"[A-Z]*", ref or "").group(0):
        n = n * 26 + (ord(ch) - 64)
    return max(0, n - 1)


def read_xlsx(p: str, max_rows: int = 2000) -> dict:
    with zipfile.ZipFile(p) as z:
        shared = []
        ss = _xml(z, "xl/sharedStrings.xml")
        if ss is not None:
            for si in ss.findall("s:si", NS):
                shared.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["s"])))
        wb = _xml(z, "xl/workbook.xml")
        rels = _rels(z, "xl/workbook.xml")
        sheets = []
        if wb is not None:
            for sh in wb.iter("{%s}sheet" % NS["s"]):
                rid = sh.get("{%s}id" % NS["r"])
                if sh.get("state") in ("hidden", "veryHidden"):
                    continue
                sheets.append((sh.get("name", ""), rels.get(rid, "")))
        out, info = [], []
        for name, part in sheets:
            root = _xml(z, part) if part else None
            if root is None:
                continue
            rows = []
            for row in root.iter("{%s}row" % NS["s"]):
                cells: Dict[int, str] = {}
                for c in row.findall("s:c", NS):
                    t = c.get("t")
                    v = c.find("s:v", NS)
                    if t == "s" and v is not None:
                        try:
                            val = shared[int(v.text)]
                        except (ValueError, IndexError, TypeError):
                            val = ""
                    elif t == "inlineStr":
                        val = "".join(x.text or "" for x in c.iter("{%s}t" % NS["s"]))
                    else:
                        val = v.text if v is not None and v.text else ""
                    cells[_col_index(c.get("r", ""))] = val.strip()
                if any(cells.values()):
                    width = max(cells) + 1
                    rows.append("\t".join(cells.get(i, "") for i in range(width)))
                if len(rows) >= max_rows:
                    break
            info.append({"name": name, "rows": len(rows)})
            out.append(f"[sheet {name}]\n" + "\n".join(rows))
    return _done("\n\n".join(out), "xlsx", sheets=info)


def read_docx(p: str) -> dict:
    with zipfile.ZipFile(p) as z:
        root = _xml(z, "word/document.xml")
    if root is None:
        return _fail("docx", "no document part")
    w = NS["w"]
    lines = []
    body = root.find("w:body", NS)
    for el in (body if body is not None else []):
        if el.tag == "{%s}p" % w:
            t = "".join(x.text or "" for x in el.iter("{%s}t" % w)).strip()
            style = el.find("w:pPr/w:pStyle", NS)
            if t:
                sv = (style.get("{%s}val" % w) if style is not None else "") or ""
                m = re.match(r"(?i)heading(\d)", sv)
                lines.append(("#" * int(m.group(1)) + " " if m else "") + t)
        elif el.tag == "{%s}tbl" % w:
            for tr in el.iter("{%s}tr" % w):
                cells = ["".join(x.text or "" for x in tc.iter("{%s}t" % w)).strip() for tc in tr.findall("w:tc", NS)]
                if any(cells):
                    lines.append(" | ".join(cells))
    return _done("\n".join(lines), "docx")


def read_textutil(p: str) -> dict:
    k = kind_of(p)
    if not os.path.exists("/usr/bin/textutil"):
        return _fail(k, f".{k} is read through textutil, which only a Mac has", True)
    r = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", p], capture_output=True, timeout=60)
    if r.returncode != 0:
        return _fail(k, "textutil could not convert the file")
    return _done(r.stdout.decode("utf-8", "replace"), k)
