"""0.10.0 (Meeting Sheet, phase 6): web pages as sources.

A site is read by a plan the user sees first: the same domain, depth 2, up to 15 pages, no sign-in, cart, policy or
duplicate pages. Automatic fetching respects robots.txt (urllib.robotparser), waits between requests and names
Pacenote in the user agent. Links to other sites are offered as separate sources, never followed. Every page that is
read becomes its own `web_page` source, so a fact points to the concrete subpage. Emails and phone numbers are
never collected: they are cut from the text before anything is stored.

  plan(url, depth=2, max_pages=15)           -> {"url", "domain", "robots", "found", "pages": [...], "external": [...]}
  fetch(plan, out_dir=None, delay=1.0)       -> {"pages": [per-page report], "sources": [web_page], "external", "summary"}
  captured_sources(items, out_dir=None)      -> sources from pages captured in the Pacenote browser (LinkedIn parsed)
CLI (registered in sheet/__main__.py): webplan --request <json>, webfetch --request <json>.
"""
from __future__ import annotations

import hashlib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

USER_AGENT = "Pacenote/0.10 (Meeting Sheet; one site at a time, started by a person; +https://pacenote.bodco.pm)"
ROBOTS_AGENT = "Pacenote"
DEFAULT_DEPTH = 2
DEFAULT_MAX_PAGES = 15
MAX_BYTES = 2_000_000
EMPTY_CHARS = 200

# ---------------------------------------------------------------- contacts: never collected

_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_PHONE = re.compile(r"(?<![\w+])\+?\(?\d(?:[\d\s()-]|\.(?=\d)){6,}\d(?!\w)")
_YEARS = re.compile(r"^\(?\d{4}\)?\s*[-.]?\s*\(?\d{4}\)?$")


def _is_phone(s: str) -> bool:
    digits = re.sub(r"\D", "", s)
    if len(digits) < 9 or len(digits) > 15:
        return False
    if _YEARS.match(s.strip()):
        return False
    return True


def scrub_contacts(text: str):
    """Cuts emails and phone numbers. Returns (clean text, how many were cut). The values are never kept."""
    if not text:
        return text or "", 0
    n = 0

    def em(_m):
        nonlocal n
        n += 1
        return "[email removed]"

    def ph(m):
        nonlocal n
        if not _is_phone(m.group(0)):
            return m.group(0)
        n += 1
        return "[phone removed]"

    text = _EMAIL.sub(em, text)
    text = _PHONE.sub(ph, text)
    return text, n


# ---------------------------------------------------------------- a small DOM on html.parser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
BLOCK = {"address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure",
         "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
         "section", "table", "tr", "td", "th", "ul", "br", "title", "button", "summary", "details"}
SKIP = {"script", "style", "noscript", "template", "svg", "iframe", "head", "canvas"}


class Node:
    __slots__ = ("tag", "attrs", "children", "parent")

    def __init__(self, tag, attrs=None, parent=None):
        self.tag = tag
        self.attrs = dict(attrs or {})
        self.children = []
        self.parent = parent

    def get(self, k, d=""):
        v = self.attrs.get(k)
        return d if v is None else v

    @property
    def classes(self):
        return set(self.get("class").split())

    def iter(self):
        for c in self.children:
            if isinstance(c, Node):
                yield c
                yield from c.iter()

    def find_all(self, tag=None, pred=None):
        return [n for n in self.iter() if (tag is None or n.tag == tag or (isinstance(tag, (set, tuple)) and n.tag in tag))
                and (pred is None or pred(n))]

    def find(self, tag=None, pred=None):
        for n in self.iter():
            if (tag is None or n.tag == tag or (isinstance(tag, (set, tuple)) and n.tag in tag)) and (pred is None or pred(n)):
                return n
        return None

    def ancestors(self):
        p = self.parent
        while p is not None:
            yield p
            p = p.parent

    def text(self) -> str:
        """Visible text with block elements on their own lines; hidden duplicates (visually-hidden) are left out."""
        out = []
        _text_into(self, out)
        lines = [re.sub(r"[ \t ]+", " ", l).strip() for l in "".join(out).split("\n")]
        return "\n".join(l for l in lines if l)


def _hidden(n: Node) -> bool:
    if n.tag in SKIP:
        return True
    cl = n.classes
    if "visually-hidden" in cl or "sr-only" in cl or "a11y-text" in cl:
        return True
    if "hidden" in n.attrs and n.tag not in ("input",):
        return True
    st = n.get("style").replace(" ", "").lower()
    return "display:none" in st


def _text_into(n: Node, out: list):
    if _hidden(n):
        return
    blk = n.tag in BLOCK
    if blk:
        out.append("\n")
    for c in n.children:
        if isinstance(c, Node):
            _text_into(c, out)
        else:
            out.append(c)
    if blk:
        out.append("\n")


class _Builder(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.cur = self.root

    def handle_starttag(self, tag, attrs):
        n = Node(tag, [(k, v if v is not None else "") for k, v in attrs], self.cur)
        self.cur.children.append(n)
        if tag not in VOID:
            self.cur = n

    def handle_startendtag(self, tag, attrs):
        n = Node(tag, [(k, v if v is not None else "") for k, v in attrs], self.cur)
        self.cur.children.append(n)

    def handle_endtag(self, tag):
        p = self.cur
        while p is not None and p.tag != tag:
            p = p.parent
        if p is not None and p.parent is not None:
            self.cur = p.parent

    def handle_data(self, data):
        self.cur.children.append(data)


def parse_html(html: str) -> Node:
    b = _Builder()
    try:
        b.feed(html or "")
        b.close()
    except Exception:   # html.parser is lenient; a broken page still gives what was read
        pass
    return b.root


def title_of(root: Node) -> str:
    t = root.find("title")
    if t is not None:
        s = "".join(c for c in t.children if isinstance(c, str)).strip()
        if s:
            return re.sub(r"\s+", " ", s)
    m = root.find("meta", lambda n: n.get("property") == "og:title")
    if m is not None and m.get("content"):
        return m.get("content").strip()
    h = root.find("h1")
    return h.text().split("\n")[0] if h is not None else ""


def main_text(root: Node) -> str:
    """The page's main content: <main> or [role=main] when present, else <body> without nav, header, footer, aside."""
    m = root.find("main") or root.find(pred=lambda n: n.get("role") == "main")
    if m is None:
        m = root.find("body") or root
        keep = Node("#main")
        for c in m.children:
            if isinstance(c, Node) and (c.tag in ("nav", "footer", "aside") or (c.tag == "header" and c.find("nav"))):
                continue
            keep.children.append(c)
        m = keep
    return m.text()


def tokens(text: str) -> int:
    """Rough token count before a model sees the text (the pipeline's size.py gives the real one when present)."""
    try:
        from . import size as _size   # pipeline agent's module (phase 2); optional
        for name in ("estimate", "count_tokens", "estimate_tokens"):
            f = getattr(_size, name, None)
            if callable(f):
                return int(f(text))
    except Exception:
        pass
    if not text:
        return 0
    cyr = sum(1 for ch in text if "Ѐ" <= ch <= "ӿ")
    return int(cyr / 2.5 + (len(text) - cyr) / 4) + 1


# ---------------------------------------------------------------- URLs and the crawl rules

_TRACK = re.compile(r"^(utm_|fbclid$|gclid$|mc_|ref$|ref_src$|_hs)")
SKIP_RULES = [
    ("sign-in", re.compile(r"/(login|log-in|signin|sign-in|signup|sign-up|register|account|my-account|auth|wp-admin|wp-login)(/|\.|$)", re.I)),
    ("cart", re.compile(r"/(cart|basket|checkout|bag|order)(/|\.|$)", re.I)),
    ("policy", re.compile(r"/(privacy|privacy-policy|policy|policies|terms|terms-of-service|tos|cookies?|cookie-policy|legal|gdpr|disclaimer|imprint|impressum)(/|\.|-|$)", re.I)),
    ("feed", re.compile(r"/(feed|rss|atom)(/|\.xml|$)|/tag/|/author/|[?&](replytocom|share)=", re.I)),
    ("file", re.compile(r"\.(pdf|jpe?g|png|gif|svg|webp|zip|gz|mp4|mp3|mov|docx?|xlsx?|pptx?|ics|css|js|json|xml)$", re.I)),
]
# Sections worth reading first on a company site (spec 4.4).
PRIORITY = [("about", 0), ("company", 0), ("team", 1), ("leadership", 1), ("people", 1), ("services", 2), ("products", 2),
            ("product", 2), ("solutions", 2), ("platform", 2), ("pricing", 3), ("cases", 3), ("case-studies", 3),
            ("customers", 3), ("clients", 3), ("work", 3), ("portfolio", 3), ("careers", 4), ("jobs", 4), ("blog", 5),
            ("news", 5), ("press", 5), ("contact", 6)]


def normalize(url: str, base: str = None):
    """Absolute http(s) URL without fragment, tracking parameters, index.html and a trailing slash; None otherwise."""
    if not url:
        return None
    url = url.strip()
    if base:
        url = urllib.parse.urljoin(base, url)
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ("http", "https") or not p.netloc:
        return None
    path = re.sub(r"/(index|default)\.(html?|php|aspx?)$", "/", p.path or "/")
    path = re.sub(r"/{2,}", "/", path)
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    q = [(k, v) for k, v in urllib.parse.parse_qsl(p.query, keep_blank_values=True) if not _TRACK.match(k)]
    query = urllib.parse.urlencode(sorted(q))
    return urllib.parse.urlunsplit((p.scheme.lower(), p.netloc.lower(), path or "/", query, ""))


def domain_of(url: str) -> str:
    h = urllib.parse.urlsplit(url).hostname or ""
    return h[4:] if h.startswith("www.") else h


def same_site(a: str, b: str) -> bool:
    return domain_of(a) == domain_of(b)


def skip_reason(url: str):
    path = urllib.parse.urlsplit(url).path + ("?" + urllib.parse.urlsplit(url).query if urllib.parse.urlsplit(url).query else "")
    for name, rx in SKIP_RULES:
        if rx.search(path):
            return name
    return None


def kind_of(url: str) -> str:
    segs = [s for s in urllib.parse.urlsplit(url).path.lower().split("/") if s]
    if not segs:
        return "home"
    for s in segs[:2]:
        for k, _ in PRIORITY:
            if s == k or s.startswith(k + "-") or s.startswith(k + "."):
                return k
    return "page"


def _rank(url: str, depth: int, order: int):
    k = kind_of(url)
    pr = dict(PRIORITY).get(k, 7 if k != "home" else -1)
    return (depth, pr, order)


def links_of(root: Node, base: str):
    """[(normalized url, link text)] in page order, first occurrence only."""
    seen, out = set(), []
    for a in root.find_all("a"):
        href = a.get("href")
        if not href or href.startswith(("mailto:", "tel:", "javascript:", "#", "sms:")):
            continue
        u = normalize(href, base)
        if not u or u in seen:
            continue
        seen.add(u)
        out.append((u, a.text().replace("\n", " ")[:120]))
    return out


# ---------------------------------------------------------------- fetching

class FetchError(Exception):
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def http_get(url: str, timeout: float = 15.0):
    """(status, final url, content type, text). Raises FetchError for transport errors."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html,text/plain;q=0.8,*/*;q=0.1",
                                               "Accept-Language": "en,uk;q=0.8"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            ctype = r.headers.get("Content-Type", "")
            raw = r.read(MAX_BYTES + 1)[:MAX_BYTES]
            cs = r.headers.get_content_charset() or "utf-8"
            return r.status, r.geturl(), ctype, raw.decode(cs, errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, url, e.headers.get("Content-Type", "") if e.headers else "", ""
    except Exception as e:  # DNS, TLS, timeout
        raise FetchError(0, str(e)[:200])


class Robots:
    """robots.txt per host; 404 = everything allowed, 401/403 = nothing allowed (as urllib.robotparser does)."""

    def __init__(self, getter=http_get):
        self.getter = getter
        self.cache = {}

    def parser(self, url: str):
        p = urllib.parse.urlsplit(url)
        key = f"{p.scheme}://{p.netloc}"
        if key in self.cache:
            return self.cache[key]
        rp = urllib.robotparser.RobotFileParser(key + "/robots.txt")
        info = {"url": key + "/robots.txt", "found": False}
        try:
            status, _u, _c, body = self.getter(key + "/robots.txt")
            if status in (401, 403):
                rp.disallow_all = True
                info["status"] = status
            elif 200 <= status < 300:
                rp.parse(body.splitlines())
                info["found"] = True
            else:
                rp.allow_all = True
                info["status"] = status
        except FetchError:
            rp.allow_all = True
            info["status"] = 0
        self.cache[key] = (rp, info)
        return self.cache[key]

    def allowed(self, url: str) -> bool:
        rp, _ = self.parser(url)
        return rp.can_fetch(ROBOTS_AGENT, url) and rp.can_fetch(USER_AGENT, url)

    def delay(self, url: str):
        rp, _ = self.parser(url)
        try:
            return rp.crawl_delay(ROBOTS_AGENT)
        except Exception:
            return None

    def info(self, url: str) -> dict:
        return dict(self.parser(url)[1])


# ---------------------------------------------------------------- the plan

def plan(url: str, depth: int = DEFAULT_DEPTH, max_pages: int = DEFAULT_MAX_PAGES, respect_robots: bool = True,
         getter=http_get) -> dict:
    """Reads the start page only (if robots.txt allows) and proposes which pages of the same site to read.

    pages: [{url, path, depth, kind, planned, note}] with note = why a page is not planned (sign-in, cart, policy,
    duplicate, robots, file, limit, feed). Depth-2 pages are found while fetching, within the same limits."""
    start = normalize(url)
    if not start:
        raise ValueError(f"not a web address: {url!r}")
    depth = max(0, min(int(depth), 3))
    max_pages = max(1, min(int(max_pages), 30))
    robots = Robots(getter)
    out = {"url": start, "domain": domain_of(start), "limits": {"same_site": True, "depth": depth, "max_pages": max_pages,
           "respect_robots": bool(respect_robots)}, "robots": robots.info(start) if respect_robots else {"checked": False},
           "pages": [], "external": [], "found": 0, "planned": 0, "start": {}}
    if respect_robots and not robots.allowed(start):
        out["start"] = {"status": "blocked", "note": "robots.txt does not allow this page"}
        out["pages"].append({"url": start, "path": urllib.parse.urlsplit(start).path, "depth": 0, "kind": "home",
                             "planned": False, "note": "robots"})
        return out
    try:
        status, final, ctype, body = getter(start)
    except FetchError as e:
        out["start"] = {"status": "error", "note": e.reason}
        return out
    if status >= 400:
        out["start"] = {"status": "error", "http": status}
        return out
    final = normalize(final) or start
    root = parse_html(body)
    out["start"] = {"status": "ok", "http": status, "title": title_of(root), "final_url": final}
    pages = [{"url": final, "path": urllib.parse.urlsplit(final).path or "/", "depth": 0, "kind": kind_of(final),
              "planned": True, "note": ""}]
    seen = {final, start}
    ext_seen = set()
    cand = []
    for i, (u, text) in enumerate(links_of(root, final)):
        if not same_site(u, final):
            d = domain_of(u)
            if d and d not in ext_seen:
                ext_seen.add(d)
                out["external"].append({"url": u, "domain": d, "text": text, "why": "linked from " + out["domain"]})
            continue
        if u in seen:
            continue
        seen.add(u)
        note = skip_reason(u)
        if not note and respect_robots and not robots.allowed(u):
            note = "robots"
        if not note and depth < 1:
            note = "limit"
        cand.append((u, text, note, i))
    cand.sort(key=lambda c: (c[2] is not None, _rank(c[0], 1, c[3])))
    left = max_pages - 1
    for u, text, note, _i in cand:
        planned = note is None and left > 0
        if note is None and not planned:
            note = "limit"
        if planned:
            left -= 1
        pages.append({"url": u, "path": urllib.parse.urlsplit(u).path or "/", "depth": 1, "kind": kind_of(u),
                      "text": text, "planned": planned, "note": note or ""})
    out["pages"] = pages
    out["found"] = len(pages)
    out["planned"] = sum(1 for p in pages if p["planned"])
    return out


# ---------------------------------------------------------------- the fetch

def _slug(s: str, n: int = 48) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return (s or "page")[:n].strip("-")


def _now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _empty_page(text: str) -> bool:
    t = text.lower()
    if len(text) < EMPTY_CHARS:
        return True
    return len(text) < 600 and any(m in t for m in ("being updated", "coming soon", "under construction", "under maintenance"))


def fetch(the_plan: dict, out_dir=None, delay: float = 1.0, getter=http_get, sleep=time.sleep, start_n: int = 1,
          id_prefix: str = "w") -> dict:
    """Reads the planned pages one by one (robots.txt and the limits again at each step), then depth-2 links found on
    them while pages are left. Each read page is a `web_page` source with its own URL; the report lists every page:
    read / empty / blocked / error / skipped / duplicate, with what was taken."""
    lim = the_plan.get("limits") or {}
    depth = int(lim.get("depth", DEFAULT_DEPTH))
    max_pages = int(lim.get("max_pages", DEFAULT_MAX_PAGES))
    respect = bool(lim.get("respect_robots", True))
    start = the_plan.get("url") or ""
    robots = Robots(getter)
    queue = [dict(p) for p in the_plan.get("pages") or [] if p.get("planned")]
    report = [dict(p, status="skipped", note=p.get("note") or "not ticked") for p in the_plan.get("pages") or []
              if not p.get("planned")]
    seen = {p["url"] for p in the_plan.get("pages") or []}
    external = list(the_plan.get("external") or [])
    ext_seen = {e.get("domain") for e in external}
    hashes = {}
    sources = []
    read = 0
    out_path = Path(out_dir).expanduser() if out_dir else None
    if out_path:
        out_path.mkdir(parents=True, exist_ok=True)
    wait = max(float(delay), 0.0)
    first = True
    while queue:
        p = queue.pop(0)
        url = p["url"]
        row = {"url": url, "path": p.get("path") or urllib.parse.urlsplit(url).path, "depth": p.get("depth", 0),
               "kind": p.get("kind") or kind_of(url)}
        if read >= max_pages:
            report.append(dict(row, status="skipped", note="limit"))
            continue
        if respect and not robots.allowed(url):
            report.append(dict(row, status="blocked", note="robots"))
            continue
        if not first:
            cd = robots.delay(url) if respect else None
            sleep(max(wait, float(cd or 0)))
        first = False
        try:
            status, final, ctype, body = getter(url)
        except FetchError as e:
            report.append(dict(row, status="error", note=e.reason))
            continue
        if status >= 400:
            report.append(dict(row, status="error", note=f"HTTP {status}", http=status))
            continue
        if ctype and "html" not in ctype and "text" not in ctype:
            report.append(dict(row, status="skipped", note="not a page (" + ctype.split(";")[0] + ")"))
            continue
        root = parse_html(body)
        title = title_of(root)
        text, cut = scrub_contacts(main_text(root))
        h = hashlib.sha1(re.sub(r"\s+", " ", text).encode("utf-8")).hexdigest()
        if h in hashes and text:
            report.append(dict(row, status="duplicate", note="same text as " + hashes[h], title=title))
            continue
        hashes[h] = url
        read += 1
        st = "empty" if _empty_page(text) else "read"
        first_line = next((l for l in text.split("\n") if len(l) > 2), "")
        rr = dict(row, status=st, title=title, chars=len(text), tokens=tokens(text),
                  taken=(first_line[:160] if st == "read" else ""), contacts_removed=cut)
        sid = f"{id_prefix}{start_n + len(sources)}"
        src = {"id": sid, "n": start_n + len(sources), "type": "web_page", "uri": url, "title": title or url,
               "size_tokens": tokens(text), "chars": len(text), "access": "ok", "used": "full" if st == "read" else "not_used",
               "auto": False, "why": [f"page of {domain_of(start)}" + (f" ({row['kind']})" if row["kind"] not in ("page", "home") else "")],
               "parent_uri": start, "checked_at": _now()}
        if st == "empty":
            src["reason"] = "the page is empty or a placeholder"
        if out_path:
            base = f"{_slug(domain_of(url))}-{_slug(urllib.parse.urlsplit(url).path or 'home', 40) or 'home'}"
            tp, k = out_path / (base + ".txt"), 2
            while tp.exists() and any(r.get("file") == str(tp) for r in report):
                tp, k = out_path / (f"{base}-{k}.txt"), k + 1
            tp.write_text(f"{title}\n{url}\n\n{text}\n", encoding="utf-8")
            src["path"] = str(tp)
            rr["file"] = str(tp)
        sources.append(src)
        rr["source_id"] = sid
        report.append(rr)
        # depth 2: links of this page, same site, same rules
        if row["depth"] < depth:
            for u, ltext in links_of(root, url):
                if not same_site(u, start or url):
                    d = domain_of(u)
                    if d and d not in ext_seen:
                        ext_seen.add(d)
                        external.append({"url": u, "domain": d, "text": ltext, "why": "linked from " + url})
                    continue
                if u in seen:
                    continue
                seen.add(u)
                why = skip_reason(u)
                nrow = {"url": u, "path": urllib.parse.urlsplit(u).path or "/", "depth": row["depth"] + 1, "kind": kind_of(u)}
                if why:
                    report.append(dict(nrow, status="skipped", note=why))
                    continue
                queue.append(nrow)
    summary = {s: sum(1 for r in report if r.get("status") == s) for s in ("read", "empty", "blocked", "error", "skipped", "duplicate")}
    summary["tokens"] = sum(r.get("tokens", 0) for r in report if r.get("status") == "read")
    return {"url": start, "pages": report, "sources": sources, "external": external, "summary": summary,
            "user_agent": USER_AGENT, "fetched_at": _now()}


def external_sources(external, start_n: int = 1, id_prefix: str = "x"):
    """Links to other sites as suggested sources (pending: nothing is opened until the user adds them)."""
    out = []
    for i, e in enumerate(external or []):
        d = e.get("domain") or domain_of(e.get("url", ""))
        t = "linkedin" if d.endswith("linkedin.com") else "web"
        out.append({"id": f"{id_prefix}{start_n + i}", "n": start_n + i, "type": t, "uri": e.get("url"), "title": e.get("text") or d,
                    "size_tokens": 0, "chars": 0, "access": "pending", "used": "not_used", "auto": True,
                    "why": [e.get("why") or "linked from the site"], "fix_action": "open_in_browser" if t == "linkedin" else None})
        if out[-1]["fix_action"] is None:
            del out[-1]["fix_action"]
    return out


# ---------------------------------------------------------------- pages captured in the Pacenote browser

def captured_sources(items, start_n: int = 1, id_prefix: str = "c"):
    """items: [{"html": path, "txt"?: path, "url", "title"?, "captured_at"?}] from PacenoteBrowser. LinkedIn pages are
    parsed (linkedin.parse) and get the state (read / authwall / hidden by owner / empty); other pages are web_page."""
    from . import linkedin as LI
    out, suggested, parsed = [], [], []
    for i, it in enumerate(items or []):
        url = it.get("url") or ""
        html = Path(it["html"]).expanduser().read_text(encoding="utf-8", errors="replace") if it.get("html") else ""
        txt = Path(it["txt"]).expanduser().read_text(encoding="utf-8", errors="replace") if it.get("txt") else ""
        n = start_n + i
        if LI.is_linkedin(url):
            r = LI.parse(html, txt, url)
            parsed.append(r)
            src = LI.to_source(r, f"{id_prefix}{n}", n, path=it.get("txt") or it.get("html"))
            suggested += r.get("suggested_sources") or []
        else:
            root = parse_html(html) if html else None
            text = txt or (main_text(root) if root else "")
            text, _cut = scrub_contacts(text)
            title = it.get("title") or (title_of(root) if root else url)
            empty = _empty_page(text)
            src = {"id": f"{id_prefix}{n}", "n": n, "type": "web_page", "uri": url, "title": title, "size_tokens": tokens(text),
                   "chars": len(text), "access": "ok", "used": "not_used" if empty else "full", "auto": False,
                   "why": ["captured in the Pacenote browser"], "path": it.get("txt") or it.get("html")}
            if empty:
                src["reason"] = "the page is empty or a placeholder"
        if it.get("captured_at"):
            src["checked_at"] = it["captured_at"]
        out.append(src)
    return {"sources": out, "suggested": suggested, "linkedin": parsed}


# ---------------------------------------------------------------- CLI

def _read(path):
    return json.loads(Path(path).expanduser().read_text(encoding="utf-8")) if path else {}


def cli(command: str, request_path=None, argv_url=None) -> int:
    import sys

    def out(obj, code=0):
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, indent=1) + "\n")
        return code

    try:
        req = _read(request_path)
    except (OSError, ValueError) as e:
        return out({"error": f"cannot read the request: {e}"}, 3)
    try:
        if command == "webplan":
            url = req.get("url") or argv_url
            if not url:
                return out({"error": "request needs url"}, 3)
            return out(plan(url, req.get("depth", DEFAULT_DEPTH), req.get("max_pages", DEFAULT_MAX_PAGES),
                            req.get("respect_robots", True)))
        if command == "webfetch":
            res = {}
            if req.get("captured"):
                res = captured_sources(req["captured"], int(req.get("start_n", 1)))
            p = req.get("plan") or (_read(req["plan_path"]) if req.get("plan_path") else None)
            if p is None and req.get("url"):
                p = plan(req["url"], req.get("depth", DEFAULT_DEPTH), req.get("max_pages", DEFAULT_MAX_PAGES),
                         req.get("respect_robots", True))
            if p is not None:
                f = fetch(p, req.get("out_dir"), float(req.get("delay", 1.0)), start_n=int(req.get("start_n", 1)))
                f["suggested"] = external_sources(f["external"])
                if res:
                    f["captured"] = res
                res = f
            if not res:
                return out({"error": "request needs plan, plan_path, url or captured"}, 3)
            return out(res)
    except ValueError as e:
        return out({"error": str(e)}, 3)
    return out({"error": f"unknown command {command!r}"}, 2)
