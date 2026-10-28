"""After the call: wrap-up and the Meetings DB page in Notion (same result as the skill's Step 4-5).

  python -m livetips_m0.wrapup_notion --md <transcript.md> --project-config <projects/<slug>.md>
      --lt <python> <lt> [--model claude-sonnet-5-5] [--tips <tips.jsonl>] [--dry-run]

Env: CLAUDE_API (Claude key), NOTION_TOKEN (internal integration token with access to the Meetings DB).
Steps: `lt wrapup-data` (numbers, clean transcript) -> one Claude call for the wrap-up (JSON) ->
find this meeting's page in the Meetings DB (Date within 20 min of the start; a Notion AI page made by the
calendar counts) -> append a "Pacenote" section there, or create a new page -> attach the transcript
as <stem>-transcript.md. Prints one JSON line: {"ok", "url", "created", "error"}.
Nothing is sent anywhere else. Audio never leaves the Mac; only the transcript text goes to Claude and Notion.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

NOTION = "https://api.notion.com/v1"
NOTION_VERSION = "2025-09-03"
ANTHROPIC = "https://api.anthropic.com/v1/messages"


# ---------------------------------------------------------------- helpers
def http(method: str, url: str, headers: dict, body=None, timeout=60, raw: bytes | None = None, ctype=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    h = dict(headers)
    if data is not None:
        h["Content-Type"] = ctype or "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                t = r.read()
                return json.loads(t) if t else {}
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")[:400]
            if not retry_later(e.code, attempt):
                raise RuntimeError(f"{method} {url.split('?')[0]} -> {e.code}: {msg}") from None


def retry_later(code: int, attempt: int) -> bool:
    """Rate limits and overloads wait 2, 5, 8 s; three tries more at most."""
    if code in (429, 502, 503, 529) and attempt < 3:
        time.sleep(2 + attempt * 3)
        return True
    return False

def notion(method, path, body=None):
    tok = os.environ.get("NOTION_TOKEN", "")
    return http(method, NOTION + path, {"Authorization": f"Bearer {tok}", "Notion-Version": NOTION_VERSION}, body)


def config_ids(cfg_path: Path) -> dict:
    """meetings_db, project_page_id, workspace_page_id from the project config (projects/<slug>.md)."""
    t = cfg_path.read_text(encoding="utf-8")
    out = {}
    for key in ("meetings_db", "project_page_id", "workspace_page_id", "risks_db"):
        m = re.search(r"\*\*" + key + r"\*\*\s*:\s*`?([^`\s]+)", t) or re.search(key + r"\s*:\s*`?([^`\s]+)", t)
        if m:
            out[key] = m.group(1).replace("collection://", "").strip()
    return out


def _head_value(head, prefixes, default=""):
    return next((l.split(":", 1)[1].strip() for l in head if l.startswith(prefixes)), default)


def header_info(md: Path) -> dict:
    """Title, start and timezone from the transcript header and the recorder's state."""
    head = md.read_text(encoding="utf-8").splitlines()[:12]
    title = next((l[len("# Live transcript:"):].strip() for l in head if l.startswith("# Live transcript:")), md.stem)
    start = _head_value(head, ("- Початок:", "- Start:"))
    try:
        t0 = dt.datetime.strptime(start, "%Y-%m-%d %H:%M:%S").astimezone()
    except ValueError:
        t0 = dt.datetime.fromtimestamp(md.stat().st_ctime).astimezone()
    tz = os.environ.get("LT_TIMEZONE") or "Europe/Kiev"
    # 2026-10-26 (owner): the page is written in the call's language ("- Мови: Я = en, дозволені = en").
    langs = next((l.split("=")[-1].strip() for l in head if l.startswith("- Мови:") or l.startswith("- Languages:")), "uk")
    lang = "en" if langs.split("+")[0].strip() == "en" else "uk"
    return {"title": title, "start": t0, "tz": "Europe/Kiev" if tz in ("Europe/Kyiv", "Europe/Uzhgorod") else tz, "lang": lang}


TXT = {
    "uk": {"actions": "Action items", "decisions": "Рішення", "agenda": "Агенда", "commit": "Зобов'язання з нашого боку",
           "new": "Нові вимоги (кандидати на зміну обсягу)", "open": "Відкриті питання", "risks": "Ризики",
           "tips": "Підказки: показано {shown}, карток {cards}, фактів {facts}, запізнілих {late}; затримка медіана {med} с, макс {mx} с",
           "prep": "Підготовка: ", "prep_yes": "використана", "prep_no": "не було",
           "tr": "Транскрипт: {n} рядків, мови {langs}, локальний файл {f}", "summary": "Підсумок", "transcript": "Транскрипт",
           "append": "Pacenote: підсумок ({hhmm})", "tr_app": "Транскрипт (Pacenote)", "write": "Ukrainian",
           "footer": "Нотатки Pacenote · транскрибовано на пристрої"},
    "en": {"actions": "Action items", "decisions": "Decisions", "agenda": "Agenda", "commit": "Our commitments",
           "new": "New requests (possible scope changes)", "open": "Open questions", "risks": "Risks",
           "tips": "Tips: shown {shown}, cards {cards}, facts {facts}, late {late}; delay median {med} s, max {mx} s",
           "prep": "Preparation: ", "prep_yes": "used", "prep_no": "none",
           "tr": "Transcript: {n} lines, languages {langs}, local file {f}", "summary": "Summary", "transcript": "Transcript",
           "append": "Pacenote: summary ({hhmm})", "tr_app": "Transcript (Pacenote)", "write": "English",
           "footer": "Notes by Pacenote · transcribed on device"},
}


# ---------------------------------------------------------------- wrap-up by Claude
SYSTEM = """You write the wrap-up of a work call for a project manager (PM), from the call transcript.
Lines are "[time] Speaker (lang): text"; "Я" is the PM. The transcript is machine speech recognition: names and
technical words can be garbled, and speaker labels can be wrong; never invent facts that are not said.
Write in {LANG}, plain and short, no long dashes. Return ONLY one JSON object:
{"name": "2-6 words in {LANG}: what was actually discussed (the meeting's own name is added in front of it)",
 "summary": "1-2 sentences",
 "action_items": [{"who": "...", "what": "...", "when": "... or empty"}],
 "decisions": ["..."], "commitments": ["what we (the PM's side) promised, with dates"],
 "new_requests": ["new asks from the other side that may change scope"],
 "open_questions": ["..."], "risks": ["..."]}
Empty lists are fine. Do not repeat the same item in two lists."""


def _correction(d: dict) -> str:
    act, before, after = d.get("action", ""), d.get("before") or {}, d.get("after") or {}
    if act == "onme_add":
        return f"- On the PM (added by the PM): {after.get('text', '')}"
    if act == "onme_remove":
        return f"- NOT on the PM (removed by the PM): {before.get('text', '')}"
    if act == "onme_edit":
        return f"- Corrected by the PM: \"{before.get('text', '')}\" is really \"{after.get('text', '')}\""
    if act == "remove":
        return f"- Wrong or irrelevant (removed by the PM): {before.get('gist', '')}"
    if act == "edit":
        return edited_card(after)
    return ""


def edited_card(after: dict) -> str:
    pts = "; ".join(after.get("items") or [])
    return (f"- Corrected by the PM: {after.get('gist', '')}" + (f" ({after.get('phrase', '')})" if after.get("phrase") else "")
            + (f": {pts}" if pts else ""))


def pm_corrections(path: Path) -> str:
    """2026-10-28 (owner): cards and "On me" lines the PM corrected, removed or added in the tips window during the
    call (<stem>.edits.jsonl). They are true and win over the transcript and the call picture."""
    if not path.exists():
        return ""
    out = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        try:
            line = _correction(json.loads(raw))
        except Exception:  # noqa: BLE001
            continue
        if line:
            out.append(line)
    return ("\n\nCORRECTIONS BY THE PM DURING THE CALL (true; they win over the transcript):\n" + "\n".join(out[-60:])) if out else ""


def claude_wrapup(transcript: str, brief: str, model: str, lang: str = "uk", provider=None) -> dict:
    """0.8.2: through the app's "After the call" route: the key, or Claude Code on the PM's Claude account."""
    from .routing import provider_from_env
    prov = provider or provider_from_env("after", timeout=180.0)
    user = (f"PREP BRIEF (may be empty):\n{brief[:14000]}\n\n" if brief else "") + f"TRANSCRIPT:\n{transcript[:120000]}"
    c = prov.complete(model=model, system=[{"text": SYSTEM.replace("{LANG}", TXT[lang]["write"])}], user=user,
                      max_tokens=2500, cache_ttl=None)
    if c.error:
        raise RuntimeError("summary request failed: " + str(c.error)[:200])
    text = c.text
    i, j = text.find("{"), text.rfind("}")
    out = json.loads(text[i:j + 1])
    try:   # 2026-10-26 (owner): the menu shows what the last call cost, the wrap-up included (Claude Code: 0, the plan)
        from .cost import cost_usd
        out["_cost"] = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
    except Exception:  # noqa: BLE001
        out["_cost"] = None
    out["_route"] = getattr(c, "route", "api")
    return out


# ---------------------------------------------------------------- blocks
def rt(s: str) -> list:
    s = s.replace(chr(0x2014), "-")   # never the long dash in Notion
    return [{"type": "text", "text": {"content": s[i:i + 1900]}} for i in range(0, len(s), 1900)] or [{"type": "text", "text": {"content": ""}}]


def h(level: int, s: str) -> dict:
    k = f"heading_{level}"
    return {"type": k, k: {"rich_text": rt(s)}}


def para(s: str) -> dict:
    return {"type": "paragraph", "paragraph": {"rich_text": rt(s)}}


def footer_blocks(lang: str) -> list:
    """Pacenote 0.8: the last blocks of a meeting page, in the page's language: a divider and one quiet line."""
    return [{"type": "divider", "divider": {}},
            {"type": "paragraph", "paragraph": {"rich_text": rt(TXT[lang]["footer"]), "color": "gray"}}]


def bullet(s: str) -> dict:
    return {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": rt(s)}}


def todo(s: str) -> dict:
    return {"type": "to_do", "to_do": {"rich_text": rt(s), "checked": False}}


def wrapup_blocks(w: dict, stats: dict, md: Path, prep_used: bool, lang: str = "uk") -> list:
    T = TXT[lang]
    sections = [(T["actions"], [action_line(a) for a in w.get("action_items", [])], todo),
                (T["decisions"], w.get("decisions", []), bullet), (T["commit"], w.get("commitments", []), bullet),
                (T["new"], w.get("new_requests", []), bullet),
                (T["open"], w.get("open_questions", []), bullet), (T["risks"], w.get("risks", []), bullet)]
    agenda = agenda_lines(md, lang)
    if agenda:
        sections.insert(1, (T["agenda"], agenda, bullet))
    b = []
    for title, items, kind in sections:
        items = [i for i in items if str(i).strip(" :")]
        if items:
            b.append(h(3, title))
            b += [kind(str(i)) for i in items]
    return b + pacenote_blocks(stats, md, prep_used, T)


def action_line(a: dict) -> str:
    return f"{a.get('who', '').strip()}: {a.get('what', '').strip()}" + (f" ({a['when']})" if a.get("when") else "")


def agenda_lines(md: Path, lang: str) -> list:
    """Pacenote 0.8 (rules/agenda.yaml > wrapup): each agenda item with Discussed, Raised or Not raised."""
    from .agenda import last_from_tips, status_label
    stem = str(md)[:-3] if str(md).endswith(".md") else str(md)
    strip = next((x for x in (last_from_tips(Path(p)) for p in (str(md) + ".tips.jsonl", stem + ".tips.jsonl")) if x), None)
    return ["{}: {}".format(str(it.get("text", "")).strip(), status_label(it, lang == "uk"))
            for it in strip or [] if str(it.get("text", "")).strip()]


def pacenote_blocks(stats: dict, md: Path, prep_used: bool, T: dict) -> list:
    tips = stats.get("tips", {})
    tr = stats.get("transcript", {})
    return [h(3, "Pacenote"),
            bullet(T["tips"].format(shown=tips.get('shown', 0), cards=tips.get('cards_fired', 0), facts=tips.get('facts_shown', 0),
                                    late=tips.get('late', 0), med=tips.get('delay_median_s', '?'), mx=tips.get('delay_max_s', '?'))),
            bullet(T["prep"] + (T["prep_yes"] if prep_used else T["prep_no"])),
            bullet(T["tr"].format(n=tr.get('lines_real', '?'), langs=", ".join((tr.get('langs') or {}).keys()), f=md.name))]


# ---------------------------------------------------------------- Notion
LINE_RX = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \(([\w+-]+)\): (.*)$")


def transcript_blocks(text: str) -> list:
    """The transcript as Notion blocks (2026-10-27, owner: a page, not a file): one paragraph per line with
    the time and the speaker in bold, headings and markers kept."""
    out = []
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln:
            continue
        m = LINE_RX.match(ln)
        if m:
            who = m.group(1) + " " + m.group(2) + ": "
            out.append({"type": "paragraph", "paragraph": {"rich_text": [
                {"type": "text", "text": {"content": who}, "annotations": {"bold": True}}] + rt(m.group(4))}})
        elif ln.startswith("# "):
            out.append(h(2, ln[2:]))
        elif ln.startswith("## "):
            out.append(h(3, ln[3:]))
        elif ln.startswith("---") and ln.endswith("---"):
            out.append({"type": "paragraph", "paragraph": {"rich_text": [
                {"type": "text", "text": {"content": ln.strip("- ")}, "annotations": {"italic": True, "color": "gray"}}]}})
        else:
            out.append(para(ln))
    return out


def transcript_page(parent_id: str, title: str, text: str) -> dict:
    """A child page under the meeting page holding the whole transcript."""
    blocks = transcript_blocks(text)
    p = notion("POST", "/pages", {"parent": {"type": "page_id", "page_id": parent_id},
                                  "properties": {"title": {"title": rt(title)}},
                                  "icon": {"type": "emoji", "emoji": "📝"},
                                  "children": blocks[:90]})
    append(p["id"], blocks[90:])
    return p


def upload_md(name: str, text: str) -> str:
    fu = notion("POST", "/file_uploads", {"filename": name, "content_type": "text/markdown"})
    boundary = "----lt" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: text/markdown\r\n\r\n").encode() + text.encode("utf-8") + f"\r\n--{boundary}--\r\n".encode()
    tok = os.environ.get("NOTION_TOKEN", "")
    url = str(fu.get("upload_url", ""))
    # Security (audit 2026-10-27): the token goes only to Notion's own API host, never to a URL from a response.
    host = urllib.parse.urlsplit(url)
    if host.scheme != "https" or not (host.hostname == "api.notion.com" or (host.hostname or "").endswith(".notion.com")):
        raise RuntimeError("Notion returned an unexpected upload address; not sending the token there")
    http("POST", url, {"Authorization": f"Bearer {tok}", "Notion-Version": NOTION_VERSION},
         raw=body, ctype=f"multipart/form-data; boundary={boundary}")
    return fu["id"]


def file_block(upload_id: str, name: str) -> dict:
    return {"type": "file", "file": {"type": "file_upload", "file_upload": {"id": upload_id}, "name": name}}


def schema(ds: str) -> dict:
    """2026-10-26: any Meetings database works. The title property, a date property ("Date" first), a text
    property for the summary ("Summary" first) and Project/Workspace (relation or select) are found by type;
    what is missing is skipped instead of failing."""
    props = notion("GET", f"/data_sources/{ds}").get("properties", {})
    by = lambda t: [n for n, v in props.items() if v.get("type") == t]  # noqa: E731
    pick = lambda t, pref: (pref if (props.get(pref) or {}).get("type") == t else (by(t) or [None])[0])  # noqa: E731
    out = {"title": (by("title") or ["Name"])[0], "date": pick("date", "Date"), "summary": None,
           "project": None, "workspace": None}
    if (props.get("Summary") or {}).get("type") == "rich_text":
        out["summary"] = "Summary"
    for key, name in (("project", "Project"), ("workspace", "Workspace")):
        t = (props.get(name) or {}).get("type")
        if t in ("relation", "select", "rich_text"):
            out[key] = (name, t)
    return out


def find_page(ds: str, start: dt.datetime, date_prop: str | None = "Date") -> dict | None:
    if not date_prop:
        return None
    lo, hi = (start - dt.timedelta(minutes=20)).isoformat(), (start + dt.timedelta(minutes=20)).isoformat()
    r = notion("POST", f"/data_sources/{ds}/query", {"filter": {"and": [
        {"property": date_prop, "date": {"on_or_after": lo}}, {"property": date_prop, "date": {"on_or_before": hi}}]},
        "page_size": 10})
    pages = r.get("results", [])
    if not pages:
        return None

    def gap(p):
        s = ((p.get("properties", {}).get(date_prop) or {}).get("date") or {}).get("start")
        try:
            return abs((dt.datetime.fromisoformat(s.replace("Z", "+00:00")) - start).total_seconds())
        except Exception:  # noqa: BLE001
            return 1e9
    return sorted(pages, key=gap)[0]


def append(page_id: str, blocks: list) -> None:
    for i in range(0, len(blocks), 90):
        notion("PATCH", f"/blocks/{page_id}/children", {"children": blocks[i:i + 90]})


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--project-config", type=Path, default=None, help="Control Tower config (meetings_db, page ids)")
    ap.add_argument("--meetings-db", default="", help="data source id of the Meetings database (used without a config)")
    ap.add_argument("--project-name", default="", help="written to a Project select or text property")
    ap.add_argument("--title", default="", help="the call's name when it was renamed during the call")
    ap.add_argument("--lt", nargs=2, required=True)
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--when", default="", help="ISO date and time of the meeting set in Start call (title date)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--find-only", action="store_true", help="only look up this meeting's page in Notion")
    return ap.parse_args(argv)


def meeting_ids(a) -> dict:
    ids = config_ids(a.project_config) if a.project_config and a.project_config.exists() else {}
    if not ids.get("meetings_db") and a.meetings_db:
        ids["meetings_db"] = a.meetings_db.replace("collection://", "").strip()
    if not ids.get("meetings_db"):
        raise RuntimeError("no Meetings database: choose one in Settings > General > Notion")
    return ids


def call_material(a):
    """(lt wrapup-data numbers, the clean transcript as plain text, the brief with the PM's corrections first)."""
    out = subprocess.run(list(a.lt) + ["wrapup-data", str(a.md)], capture_output=True, text=True, timeout=120).stdout
    stats = json.loads(out[out.find("{"):])
    clean = Path(stats["transcript"]["clean_file"]).read_text(encoding="utf-8")
    plain = re.sub(r"\\([][<>*_#])", r"\1", clean)
    if stats["transcript"].get("lines_real", 0) < 5:
        raise RuntimeError("fewer than 5 transcript lines: nothing to write")
    brief_f = Path(str(a.md)[:-3] + ".brief.md")
    brief = brief_f.read_text(encoding="utf-8") if brief_f.exists() else ""
    brief = (pm_corrections(Path(str(a.md)[:-3] + ".edits.jsonl")).strip() + "\n\n" + brief).strip()
    return stats, plain, brief


def call_info(a) -> dict:
    info = header_info(a.md)
    if a.title.strip():
        info["title"] = a.title.strip()
    if a.when:   # 2026-10-26 (owner): the title's date is the meeting time set in the app, not the recording start
        try:
            info["start"] = dt.datetime.fromisoformat(a.when.replace("Z", "+00:00")).astimezone()
        except ValueError:
            pass
    return info


def charge(cost) -> None:
    """The wrap-up goes into the same monthly ledger as the tips."""
    if not cost:
        return
    try:
        from .cost import BudgetGuard
        BudgetGuard(os.environ.get("LT_LEDGER", "~/.livetips/spend.json"), 1e9, 1e9, 1e9).add(float(cost))
    except Exception:  # noqa: BLE001
        pass


def link_props(sc: dict, ids: dict, existing: dict, project_name: str) -> dict:
    """Project and Workspace: a relation from the config's page ids, or the project's name as a select or text."""
    upd = {}
    for key, idkey, val in (("project", "project_page_id", project_name), ("workspace", "workspace_page_id", "")):
        if not sc[key]:
            continue
        name, t = sc[key]
        if not (existing.get(name) or {}).get(t):
            upd.update(link_value(name, t, ids.get(idkey), val))
    return upd


def link_value(name: str, t: str, page_id, val: str) -> dict:
    if t == "relation" and page_id:
        return {name: {"relation": [{"id": page_id}]}}
    if t == "select" and val:
        return {name: {"select": {"name": val[:100]}}}
    if t == "rich_text" and val:
        return {name: {"rich_text": rt(val)}}
    return {}


def page_name(title: str, topic: str) -> str:
    """2026-10-26 (owner): the page title starts with the meeting's name, then what it was about."""
    topic = (topic or "").strip()
    return title if not topic or topic.lower() in title.lower() else title + ": " + topic


def new_page_props(sc: dict, name: str, start: dt.datetime, summary: str) -> dict:
    props = {sc["title"]: {"title": rt(name + " ") + [
        {"type": "mention", "mention": {"type": "date", "date": {"start": start.isoformat(timespec="minutes")}}}]}}
    if sc["date"]:
        props[sc["date"]] = {"date": {"start": start.isoformat(timespec="seconds")}}
    if sc["summary"]:
        props[sc["summary"]] = {"rich_text": rt(summary)}
    return props


def add_footer(page_id: str, lang: str) -> None:
    try:
        append(page_id, footer_blocks(lang))   # the footer never fails the wrap-up
    except Exception:  # noqa: BLE001
        pass


def write_to_page(page: dict, sc, ids, a, w, blocks, plain, info, lang) -> dict:
    """Append a Pacenote section to the meeting's existing page."""
    upd = link_props(sc, ids, page.get("properties", {}), a.project_name)
    if upd:
        notion("PATCH", f"/pages/{page['id']}", {"properties": upd})
    hhmm = dt.datetime.now().strftime("%H:%M")
    append(page["id"], [h(2, TXT[lang]["append"].format(hhmm=hhmm)), para(w.get("summary", ""))] + blocks
           + [h(3, TXT[lang]["tr_app"])])
    transcript_page(page["id"], TXT[lang]["tr_app"] + " · " + info["title"], plain)
    add_footer(page["id"], lang)
    return {"ok": True, "url": page.get("url")}


def create_page(sc, ids, a, w, blocks, plain, info, lang) -> dict:
    """A new page in the Meetings database."""
    name = page_name(info["title"], w.get("name"))
    props = new_page_props(sc, name, info["start"], w.get("summary", ""))
    props.update(link_props(sc, ids, {}, a.project_name))
    p = notion("POST", "/pages", {"parent": {"type": "data_source_id", "data_source_id": ids["meetings_db"]},
                                  "properties": props,
                                  "children": [h(2, TXT[lang]["summary"])] + blocks + [h(2, TXT[lang]["transcript"])]})
    transcript_page(p["id"], TXT[lang]["transcript"] + " · " + name, plain)
    add_footer(p["id"], lang)
    return {"ok": True, "url": p.get("url"), "created": True}


def run(a, res: dict) -> int:
    ids = meeting_ids(a)
    sc = schema(ids["meetings_db"])
    if a.find_only:
        p = find_page(ids["meetings_db"], header_info(a.md)["start"], sc["date"])
        print(json.dumps({"ok": True, "found": bool(p), "url": p and p.get("url")}))
        return 0
    stats, plain, brief = call_material(a)
    info = call_info(a)
    lang = info.get("lang", "uk")
    w = claude_wrapup(plain, brief, a.model, lang)
    blocks = wrapup_blocks(w, stats, a.md, bool(brief), lang)
    if a.dry_run:
        print(json.dumps({"ok": True, "dry_run": True, "name": w.get("name"), "summary": w.get("summary"),
                          "blocks": len(blocks), "ids": ids}, ensure_ascii=False))
        return 0
    res["cost_usd"] = w.get("_cost")
    charge(w.get("_cost"))
    page = find_page(ids["meetings_db"], info["start"], sc["date"])
    if page:
        res.update(write_to_page(page, sc, ids, a, w, blocks, plain, info, lang))
    else:
        res.update(create_page(sc, ids, a, w, blocks, plain, info, lang))
    return None


def main(argv=None) -> int:
    a = parse_args(argv)
    res = {"ok": False, "url": None, "created": False, "error": None, "cost_usd": None}
    try:
        done = run(a, res)
        if done is not None:
            return done
    except Exception as e:  # noqa: BLE001
        res["error"] = f"{type(e).__name__}: {e}"[:600]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
