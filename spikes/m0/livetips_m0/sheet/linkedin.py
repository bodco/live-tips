"""0.10.0 (Meeting Sheet, phase 6): a LinkedIn page captured in the Pacenote browser, turned into facts-ready parts.

Only the profile is taken: header, About, Featured, Experience, Education, Skills, Certifications, Languages.
Left out: ads, "People you may know", "People also viewed", "Who viewed", the owner's analytics, activity
("Liked by", reposts), recommendations and anything else. Emails and phone numbers are never collected.
Name variants become aliases; when sections give different numbers for the same thing, both stay with a question;
links in Featured are offered as new sources (nothing opens until the user says so).

State of the page: read | authwall (no LinkedIn session in this window) | hidden_by_owner (the owner limits who sees
the profile) | empty (it opened, nothing to read).

  parse(html, text="", url="") -> dict    (see the keys at the end of parse)
  to_source(result, id, n, path=None)     -> a `linkedin` source for sheet.sources
A capture of several pages (profile + section detail pages) wraps each page in
<article data-pacenote-page="<url>" data-pacenote-title="...">...</article>.
"""
from __future__ import annotations

import difflib
import re
import urllib.parse

from .web import Node, parse_html, scrub_contacts, title_of, tokens

SECTIONS = {
    "about": ("about", "summary"),
    "featured": ("featured",),
    "experience": ("experience",),
    "education": ("education",),
    "skills": ("skills",),
    "certifications": ("licenses & certifications", "licenses and certifications", "certifications", "licenses"),
    "languages": ("languages",),
}
ORDER = ["about", "featured", "experience", "education", "skills", "certifications", "languages"]
# Known blocks that are never facts about the contact (reported as left out).
DROPPED = {
    "ads": ("promoted", "ad", "ads", "sponsored"),
    "people you may know": ("people you may know", "people you may know from", "more profiles for you", "people also viewed",
                            "other similar profiles", "explore premium profiles", "who your viewers also viewed"),
    "who viewed": ("who viewed your profile", "who viewed", "profile viewers"),
    "owner analytics": ("analytics", "resources", "your dashboard", "private to you"),
    "activity (liked by, reposts)": ("activity", "posts", "more activity"),
    "contact info": ("contact info", "contact information"),
}
DETAIL_RX = re.compile(r"/in/[^/]+/details/([a-z-]+)", re.I)
SHOW_ALL_RX = re.compile(r"show all\s+(\d+)\s+([a-z &-]+)", re.I)
UI_LINES = {"message", "connect", "follow", "more", "pending", "open to", "add profile section", "enhance profile",
            "resources", "contact info", "show all", "see more", "show more", "…see more", "...see more", "see less",
            "show credential", "visit my website", "following", "endorse", "edit", "save", "send"}
DEGREE = re.compile(r"^(·\s*)?(1st|2nd|3rd|3rd\+)$|^(he|she|they)/(him|her|them)$", re.I)
COUNT_NOUNS = {"user": "users", "users": "users", "customer": "customers", "customers": "customers", "client": "clients",
               "clients": "clients", "people": "people", "person": "people", "engineer": "engineers", "engineers": "engineers",
               "employee": "employees", "employees": "employees", "member": "members", "members": "members",
               "download": "downloads", "downloads": "downloads", "install": "installs", "installs": "installs",
               "student": "students", "students": "students", "developer": "developers", "developers": "developers",
               "company": "companies", "companies": "companies", "team": "teams", "teams": "teams",
               "subscriber": "subscribers", "subscribers": "subscribers", "merchant": "merchants", "merchants": "merchants",
               "country": "countries", "countries": "countries", "reports": "reports", "projects": "projects",
               "products": "products", "stores": "stores", "hospitals": "hospitals", "patients": "patients"}
NUM_RX = re.compile(r"(?<![\w.,])(\d{1,3}(?:[,  ]\d{3})+|\d+(?:\.\d+)?)\s*([kKmM])?\s*(\+)?\s+(?:active\s+|monthly\s+|daily\s+|paying\s+)?([A-Za-z]+)")
AUTHWALL = ("join linkedin", "sign in to view", "join now to see", "sign in to see", "join to view", "sign in or join",
            "authwall", "join now", "to view the full profile")
HIDDEN = ("this profile is not available", "profile isn't available", "profile is not available", "this profile is private",
          "profile is private", "profile not available", "this page doesn't exist", "this page doesn’t exist",
          "profile is not public", "linkedin member")


def is_linkedin(url: str) -> bool:
    h = (urllib.parse.urlsplit(url or "").hostname or "").lower()
    return h == "linkedin.com" or h.endswith(".linkedin.com")


def page_kind(url: str) -> str:
    p = urllib.parse.urlsplit(url or "").path.lower()
    if DETAIL_RX.search(p):
        return "detail"
    if p.startswith("/in/"):
        return "profile"
    if p.startswith("/company/") or p.startswith("/school/"):
        return "company"
    if "authwall" in p or p.startswith("/login") or p.startswith("/signup"):
        return "authwall"
    return "other"


def detail_url(profile_url: str, section: str) -> str:
    """https://www.linkedin.com/in/<id>/details/<section>/ (the same list the Swift capture plan opens)."""
    p = urllib.parse.urlsplit(profile_url)
    m = re.match(r"(/in/[^/]+)", p.path)
    base = m.group(1) if m else p.path.rstrip("/")
    return f"https://www.linkedin.com{base}/details/{section}/"


def _norm_heading(s: str) -> str:
    s = s.split("\n")[0].strip().lower()
    s = re.sub(r"\s+", " ", s)
    return s


def _section_name(h: str):
    h = _norm_heading(h)
    for k, names in SECTIONS.items():
        if h in names:
            return k, None
    for k, names in DROPPED.items():
        if h in names or any(h.startswith(n) for n in names if len(n) > 3):
            return None, k
    return None, "other: " + h if h else None


def _heading(sec: Node) -> str:
    for n in sec.iter():
        if n.tag in ("h2", "h3"):
            t = n.text()
            if t:
                return t
    for n in sec.iter():
        if n.tag == "div" and n.get("id") and n.get("id") != "":
            return n.get("id").replace("_", " ").replace("-", " ")
    return ""


def _anchor_id(sec: Node) -> str:
    if sec.get("id"):
        return sec.get("id")
    for n in sec.iter():
        if n.get("id"):
            return n.get("id")
    return ""


def _clean_lines(text: str, drop_name=None):
    out = []
    for l in text.split("\n"):
        s = l.strip()
        ls = s.lower().strip(" .…")
        if not s or ls in UI_LINES or DEGREE.match(s) or ls.startswith("show all") or ls.startswith("liked by") \
                or "reposted this" in ls or ls.startswith("promoted"):
            continue
        if drop_name and s == drop_name:
            continue
        if out and out[-1] == s:      # LinkedIn repeats a visible span for screen readers
            continue
        out.append(s)
    return out


def _top_items(sec: Node):
    lis = [n for n in sec.find_all("li") if not any(a.tag == "li" for a in n.ancestors() if a is not sec and _inside(a, sec))]
    return lis


def _inside(a: Node, sec: Node) -> bool:
    p = a
    while p is not None:
        if p is sec:
            return True
        p = p.parent
    return False


def _pages(root: Node, url: str):
    arts = root.find_all("article", lambda n: bool(n.get("data-pacenote-page")))
    if arts:
        return [(a.get("data-pacenote-page"), a.get("data-pacenote-title"), a) for a in arts]
    return [(url, title_of(root), root)]


def _name_from_title(t: str) -> str:
    parts = [p.strip() for p in re.split(r"\s+[|\-–]\s+", t or "") if p.strip()]
    parts = [p for p in parts if p.lower() not in ("linkedin",) and _section_name(p)[0] is None
             and not p.lower().startswith(("experience", "education", "skills", "licenses", "languages", "certifications"))]
    if not parts:
        return ""
    cand = re.sub(r"^\(\d+\)\s*", "", parts[0])
    return cand if 1 <= len(cand.split()) <= 5 and not any(ch.isdigit() for ch in cand) else ""


def _not_a_name(s: str) -> bool:
    t = (s or "").lower().strip()
    return not t or any(m in t for m in AUTHWALL + HIDDEN) or t in ("sign in", "sign up", "linkedin", "welcome back")


def merge_names(names):
    """(primary, aliases): the first name wins; similar variants (a shared word, or close spelling) become aliases."""
    clean = []
    for n in names:
        n = re.sub(r"\s+", " ", (n or "").strip())
        if n and n not in clean and not _not_a_name(n):
            clean.append(n)
    if not clean:
        return "", []
    primary = clean[0]
    pw = {w.lower().strip(".,") for w in primary.split() if len(w) > 1}
    aliases = []
    for n in clean[1:]:
        nw = {w.lower().strip(".,") for w in n.split() if len(w) > 1}
        if pw & nw or difflib.SequenceMatcher(None, primary.lower(), n.lower()).ratio() >= 0.75:
            aliases.append(n)
    return primary, aliases


def _numbers(items):
    """items: [(section, label, text)] -> [{"what", "values": [{"value", "section", "label", "quote"}], "question"}]."""
    found = {}
    for section, label, text in items:
        for m in NUM_RX.finditer(text):
            noun = COUNT_NOUNS.get(m.group(4).lower())
            if not noun:
                continue
            raw = m.group(1)
            val = float(re.sub(r"[,  ]", "", raw))
            mult = {"k": 1e3, "m": 1e6}.get((m.group(2) or "").lower(), 1)
            val *= mult
            if val < 100 and not m.group(3):
                continue
            shown = m.group(0)[: m.end(3) - m.start(0)] if m.group(3) else (raw + (m.group(2) or ""))
            lo = max(0, m.start() - 60)
            quote = text[lo: m.end() + 40].replace("\n", " ").strip()
            found.setdefault(noun, []).append({"value": shown.strip(), "number": val, "section": section, "label": label, "quote": quote})
    out = []
    for noun, vals in found.items():
        distinct = {v["number"] for v in vals}
        if len(distinct) < 2:
            continue
        parts = ", ".join(f"{v['value']} ({v['section']}{', ' + v['label'] if v['label'] else ''})" for v in vals)
        out.append({"what": noun, "values": vals,
                    "question": f"The profile gives different numbers of {noun}: {parts}. Which one is current, and what does each count?"})
    return out


def _state(text_all: str, html: str, url: str, has_profile: bool):
    t = text_all.lower()
    signed_in = ("global-nav" in html) or ('name="pacenote:session" content="signed_in"' in html) or bool(re.search(r"\bmy network\b", t) and re.search(r"\bmessaging\b", t))
    hidden = any(m in t for m in HIDDEN)
    wall = any(m in t for m in AUTHWALL) or "authwall" in (url or "").lower()
    if has_profile:
        return "read", signed_in, "The profile was read."
    if hidden and (signed_in or "linkedin member" in t or not wall):
        return "hidden_by_owner", signed_in, ("LinkedIn opened, but the owner limits who can see this profile. Signing in "
                                              "does not change that: use their PDF, paste the text or fill it in by hand.")
    if wall:
        return "authwall", signed_in, ("LinkedIn asks to sign in: this window has no LinkedIn session. Sign in in the "
                                       "Pacenote browser yourself and add the page again, or use Save to PDF.")
    return "empty", signed_in, "The page opened, but there is no profile on it."


def parse(html: str, text: str = "", url: str = "") -> dict:
    root = parse_html(html or "")
    pages = _pages(root, url)
    url = url or pages[0][0] or ""
    names = []
    header = {}
    sections = {k: {"items": [], "text": "", "url": None, "expanded": False, "shown": None, "total": None} for k in ORDER}
    left_out = []
    other = []
    not_received = []
    contacts = 0
    for purl, ptitle, proot in pages:
        kind = page_kind(purl or url)
        dm = DETAIL_RX.search(urllib.parse.urlsplit(purl or "").path)
        if ptitle:
            names.append(_name_from_title(ptitle))
        tt = proot.find("title")
        if tt is not None:
            names.append(_name_from_title(title_of(proot)))
        main = proot.find("main") or proot
        h1 = main.find("h1")
        if h1 is not None and h1.text() and not _not_a_name(h1.text().split("\n")[0]):
            names.append(h1.text().split("\n")[0])
        secs = [s for s in main.find_all("section") if not any(a.tag == "section" for a in s.ancestors() if _inside(a, main) and a is not main)]
        if kind == "detail" and dm:
            dname = {"skills": "skills", "experience": "experience", "education": "education", "certifications": "certifications",
                     "languages": "languages", "featured": "featured", "about": "about"}.get(dm.group(1).lower())
            if dname:
                body = Node("#detail")
                body.children = [c for c in main.children]
                secs = [(dname, body)]
        for s in secs:
            if isinstance(s, tuple):
                name, sec = s
                dropped = None
                from_detail = True
            else:
                sec = s
                from_detail = False
                if sec.find("h1") is not None and not header:
                    header = _header(sec)
                    if _not_a_name(header.get("name", "")):
                        header = {}
                    continue
                if sec.find("h1") is not None:
                    continue
                aid = _anchor_id(sec).lower()
                name, dropped = _section_name(_heading(sec))
                if name is None and aid in SECTIONS:
                    name, dropped = aid, None
                if name is None and aid and any(aid == n.replace(" ", "_") or aid == n for v in DROPPED.values() for n in v):
                    dropped = next(k for k, v in DROPPED.items() if aid in v or aid.replace("_", " ") in v)
            if name is None:
                if dropped:
                    if dropped.startswith("other: "):
                        other.append(dropped[7:])
                    elif dropped not in left_out:
                        left_out.append(dropped)
                continue
            _fill(sections[name], name, sec, purl or url, from_detail)
    # sections in an <aside> outside <main> (People you may know, ads) are never read; name them in the report
    for a in root.find_all("aside"):
        h = _heading(a)
        _n, d = _section_name(h)
        if d and not d.startswith("other: ") and d not in left_out:
            left_out.append(d)
    if root.find(pred=lambda n: "ad-banner" in n.get("class") or "data-ad-banner" in n.attrs):
        if "ads" not in left_out:
            left_out.append("ads")
    # contacts: cut from every text we keep
    for k in ORDER:
        sec = sections[k]
        sec["text"], c = scrub_contacts(sec["text"])
        contacts += c
        for it in sec["items"]:
            it["text"], c = scrub_contacts(it["text"])
            contacts += c
            it["lines"] = [scrub_contacts(l)[0] for l in it["lines"]]
            it["quote"] = scrub_contacts(it["quote"])[0]
    for f in ("headline", "location"):
        if header.get(f):
            header[f], c = scrub_contacts(header[f])
            contacts += c
    if header.get("contact_info_link"):
        header.pop("contact_info_link")
    for k in ORDER:
        s = sections[k]
        if s["total"] and len(s["items"]) < s["total"] and not s["expanded"]:
            not_received.append({"section": k, "shown": len(s["items"]), "total": s["total"],
                                 "note": f"{k.capitalize()}: {len(s['items'])} of {s['total']} on the profile page; the details page was not captured"})
    primary, aliases = merge_names([header.get("name")] + names)
    has_profile = bool(header.get("name")) or any(sections[k]["items"] or sections[k]["text"] for k in ORDER)
    plain = (text or "") + "\n" + root.text()
    state, signed_in, reason = _state(plain, html or "", url, has_profile)
    if state != "read":
        primary, aliases = "", []
    featured_links = []
    for it in sections["featured"]["items"]:
        for href, label in it.get("links", []):
            featured_links.append({"url": href, "title": label or href, "domain": _host(href)})
    seen = set()
    suggested = []
    for fl in featured_links:
        if fl["url"] in seen:
            continue
        seen.add(fl["url"])
        suggested.append({"type": "web", "uri": fl["url"], "title": fl["title"], "access": "pending", "used": "not_used",
                          "auto": True, "why": ["found in Featured on LinkedIn"], "size_tokens": 0, "chars": 0})
    facts = _facts(primary, aliases, header, sections, url)
    num_items = [(f["section"], f.get("label") or "", f["text"]) for f in facts if f["section"] != "header"]
    numbers = _numbers(num_items)
    taken = []
    for k in ORDER:
        s = sections[k]
        if s["items"] or s["text"]:
            n = len(s["items"])
            extra = ", expanded" if s["expanded"] else ""
            taken.append(f"{k.capitalize()}" + (f" ({n}{extra})" if k not in ("about",) and n else ""))
    if header.get("name"):
        taken.insert(0, "Header")
    text_all = "\n\n".join(f["text"] for f in facts)
    return {
        "kind": page_kind(url), "url": url, "state": state, "state_reason": reason, "signed_in": signed_in,
        "name": primary, "aliases": aliases, "headline": header.get("headline", ""), "location": header.get("location", ""),
        "sections": {k: sections[k] for k in ORDER if sections[k]["items"] or sections[k]["text"]},
        "facts": facts if state == "read" else [], "numbers_to_check": numbers if state == "read" else [],
        "featured_links": featured_links, "suggested_sources": suggested if state == "read" else [],
        "taken": taken if state == "read" else [], "left_out": left_out, "other_sections": other,
        "not_received": not_received, "contacts_removed": contacts,
        "chars": len(text_all), "size_tokens": tokens(text_all), "text": text_all,
    }


def _host(u):
    h = (urllib.parse.urlsplit(u).hostname or "")
    return h[4:] if h.startswith("www.") else h


def _header(sec: Node) -> dict:
    h1 = sec.find("h1")
    name = h1.text().split("\n")[0] if h1 is not None else ""
    lines = _clean_lines(sec.text(), drop_name=name)
    lines = [l for l in lines if not re.search(r"\b\d[\d,+]*\s+(connections|followers)\b", l, re.I)
             and l.lower() not in ("contact info",) and not l.lower().startswith(("contact info", "talks about"))]
    out = {"name": name}
    if lines:
        out["headline"] = lines[0]
    for l in lines[1:4]:
        if "," in l or l.lower().endswith(("area", "metropolitan area")):
            out["location"] = l
            break
    if sec.find("a", lambda a: "contact-info" in a.get("href")):
        out["contact_info_link"] = True
    return out


def _fill(sec_out: dict, name: str, sec: Node, purl: str, from_detail: bool):
    full = sec.text()
    m = SHOW_ALL_RX.search(full)
    if m and not from_detail:
        sec_out["total"] = int(m.group(1))
    head = _heading(sec) if not from_detail else ""
    items = []
    for li in _top_items(sec):
        lines = _clean_lines(li.text())
        if not lines:
            continue
        low = " ".join(lines).lower()
        if "reposted this" in li.text().lower() or low.startswith(("promoted", "liked by")):
            continue
        links = []
        if name == "featured":
            for a in li.find_all("a"):
                href = a.get("href")
                if href.startswith(("http://", "https://")) and not href.startswith(("mailto:", "tel:")):
                    h = _host(href)
                    if h.endswith("linkedin.com") and "/pulse/" not in href:
                        continue
                    links.append((href.split("?")[0] if "linkedin.com" in h else href, _clean_lines(a.text())[0] if _clean_lines(a.text()) else ""))
        txt = "\n".join(lines)
        items.append({"lines": lines, "text": txt, "quote": " · ".join(lines)[:240], "url": purl, "links": links})
    if name == "about" or not items:
        body = [l for l in _clean_lines(full) if _norm_heading(l) != _norm_heading(head) and not SHOW_ALL_RX.search(l)]
        if body and name == "about":
            sec_out["text"] = "\n".join(body)
            sec_out["url"] = purl
            return
        if body and name != "featured":
            items = [{"lines": body, "text": "\n".join(body), "quote": " · ".join(body)[:240], "url": purl, "links": []}]
    if from_detail and items:
        sec_out["items"] = items          # the detail page lists everything; it replaces the profile's short list
        sec_out["expanded"] = True
        sec_out["url"] = purl
    elif not sec_out["expanded"]:
        have = {i["text"] for i in sec_out["items"]}
        sec_out["items"] += [i for i in items if i["text"] not in have]
        sec_out["url"] = sec_out["url"] or purl


def _facts(name, aliases, header, sections, url):
    facts = []

    def add(section, label, text, quote, purl):
        facts.append({"section": section, "label": label, "text": text,
                      "locator": {"section": section, "quote": quote[:240], "url": purl or url}})

    if name:
        add("header", "name", name + (f" (also: {', '.join(aliases)})" if aliases else ""), name, url)
    if header.get("headline"):
        add("header", "headline", header["headline"], header["headline"], url)
    if header.get("location"):
        add("header", "location", header["location"], header["location"], url)
    for k in ORDER:
        s = sections[k]
        if s["text"]:
            add(k, k, s["text"], s["text"][:240], s["url"])
        for it in s["items"]:
            label = it["lines"][0] if it["lines"] else k
            if k == "experience" and len(it["lines"]) > 1:
                label = f"{it['lines'][0]} at {it['lines'][1].split(' · ')[0]}"
            add(k, label, it["text"], it["quote"], it["url"])
    return facts


def to_source(result: dict, sid: str, n: int, path=None) -> dict:
    """A `linkedin` source; access ok only when the profile was read, else pending with what the user can do."""
    st = result.get("state")
    src = {"id": sid, "n": n, "type": "linkedin", "uri": result.get("url"), "title": (result.get("name") or "LinkedIn profile") + " (LinkedIn)",
           "size_tokens": result.get("size_tokens", 0), "chars": result.get("chars", 0), "auto": False,
           "why": ["captured in the Pacenote browser"], "linkedin_state": st}
    if path:
        src["path"] = path
    if st == "read":
        src.update(access="ok", used="full")
    elif st == "authwall":
        src.update(access="denied", access_reason="authwall", fix_action="open_in_browser", used="not_used", reason=result.get("state_reason"))
    elif st == "hidden_by_owner":
        src.update(access="denied", access_reason="hidden_by_owner", fix_action="save_as_pdf", used="not_used", reason=result.get("state_reason"))
    else:
        src.update(access="ok", access_reason="empty", fix_action="paste_text", used="not_used", reason=result.get("state_reason"))
    return src


def parse_file(html_path: str, txt_path: str = None, url: str = "") -> dict:
    from pathlib import Path
    html = Path(html_path).expanduser().read_text(encoding="utf-8", errors="replace")
    text = Path(txt_path).expanduser().read_text(encoding="utf-8", errors="replace") if txt_path else ""
    if not url:
        m = re.search(r'<meta name="pacenote:url" content="([^"]+)"', html)
        url = m.group(1) if m else ""
    return parse(html, text, url)
