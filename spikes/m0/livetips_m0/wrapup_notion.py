"""After the call: wrap-up and the Meetings DB page in Notion (same result as the skill's Step 4-5).

  python -m livetips_m0.wrapup_notion --md <transcript.md> --project-config <projects/<slug>.md>
      --lt <python> <lt> [--model claude-sonnet-5-5] [--tips <tips.jsonl>] [--dry-run]

Env: CLAUDE_API (Claude key), NOTION_TOKEN (internal integration token with access to the Meetings DB).
Steps: `lt wrapup-data` (numbers, clean transcript) -> one Claude call for the wrap-up (JSON) ->
find this meeting's page in the Meetings DB (Date within 20 min of the start; a Notion AI page made by the
calendar counts) -> append a "Live Tips" section there, or create a new page -> attach the transcript
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
            if e.code in (429, 502, 503, 529) and attempt < 3:
                time.sleep(2 + attempt * 3)
                continue
            raise RuntimeError(f"{method} {url.split('?')[0]} -> {e.code}: {msg}") from None


def notion(method, path, body=None):
    tok = os.environ.get("NOTION_TOKEN", "")
    return http(method, NOTION + path, {"Authorization": f"Bearer {tok}", "Notion-Version": NOTION_VERSION}, body)


def config_ids(cfg_path: Path) -> dict:
    """meetings_db, project_page_id, workspace_page_id from the project config (projects/<slug>.md)."""
    t = cfg_path.read_text(encoding="utf-8")
    out = {}
    for key in ("meetings_db", "project_page_id", "workspace_page_id"):
        m = re.search(r"\*\*" + key + r"\*\*\s*:\s*`?([^`\s]+)", t) or re.search(key + r"\s*:\s*`?([^`\s]+)", t)
        if m:
            out[key] = m.group(1).replace("collection://", "").strip()
    return out


def header_info(md: Path) -> dict:
    """Title, start and timezone from the transcript header and the recorder's state."""
    head = md.read_text(encoding="utf-8").splitlines()[:12]
    title = next((l[len("# Live transcript:"):].strip() for l in head if l.startswith("# Live transcript:")), md.stem)
    start = next((l.split(":", 1)[1].strip() for l in head if l.startswith("- Початок:") or l.startswith("- Start:")), "")
    try:
        t0 = dt.datetime.strptime(start, "%Y-%m-%d %H:%M:%S").astimezone()
    except ValueError:
        t0 = dt.datetime.fromtimestamp(md.stat().st_ctime).astimezone()
    tz = os.environ.get("LT_TIMEZONE") or "Europe/Kiev"
    return {"title": title, "start": t0, "tz": "Europe/Kiev" if tz in ("Europe/Kyiv", "Europe/Uzhgorod") else tz}


# ---------------------------------------------------------------- wrap-up by Claude
SYSTEM = """You write the wrap-up of a work call for a project manager (PM), from the call transcript.
Lines are "[time] Speaker (lang): text"; "Я" is the PM. The transcript is machine speech recognition: names and
technical words can be garbled, and speaker labels can be wrong; never invent facts that are not said.
Write in Ukrainian (internal notes), plain and short, no long dashes. Return ONLY one JSON object:
{"name": "2-6 word meeting name in the language of the call, about what was actually discussed",
 "summary": "1-2 sentences",
 "action_items": [{"who": "...", "what": "...", "when": "... or empty"}],
 "decisions": ["..."], "commitments": ["what we (the PM's side) promised, with dates"],
 "new_requests": ["new asks from the other side that may change scope"],
 "open_questions": ["..."], "risks": ["..."]}
Empty lists are fine. Do not repeat the same item in two lists."""


def claude_wrapup(transcript: str, brief: str, model: str) -> dict:
    key = os.environ.get("CLAUDE_API", "")
    user = (f"PREP BRIEF (may be empty):\n{brief[:6000]}\n\n" if brief else "") + f"TRANSCRIPT:\n{transcript[:120000]}"
    r = http("POST", ANTHROPIC, {"x-api-key": key, "anthropic-version": "2023-06-01"},
             {"model": model, "max_tokens": 2500, "system": SYSTEM,
              "messages": [{"role": "user", "content": user}]}, timeout=180)
    text = "".join(b.get("text", "") for b in r.get("content", []) if b.get("type") == "text")
    i, j = text.find("{"), text.rfind("}")
    return json.loads(text[i:j + 1])


# ---------------------------------------------------------------- blocks
def rt(s: str) -> list:
    s = s.replace(chr(0x2014), "-")   # never the long dash in Notion
    return [{"type": "text", "text": {"content": s[i:i + 1900]}} for i in range(0, len(s), 1900)] or [{"type": "text", "text": {"content": ""}}]


def h(level: int, s: str) -> dict:
    k = f"heading_{level}"
    return {"type": k, k: {"rich_text": rt(s)}}


def para(s: str) -> dict:
    return {"type": "paragraph", "paragraph": {"rich_text": rt(s)}}


def bullet(s: str) -> dict:
    return {"type": "bulleted_list_item", "bulleted_list_item": {"rich_text": rt(s)}}


def todo(s: str) -> dict:
    return {"type": "to_do", "to_do": {"rich_text": rt(s), "checked": False}}


def wrapup_blocks(w: dict, stats: dict, md: Path, prep_used: bool) -> list:
    b = []
    sections = [("Action items", [f"{a.get('who', '').strip()}: {a.get('what', '').strip()}" + (f" ({a['when']})" if a.get("when") else "")
                                  for a in w.get("action_items", [])], todo),
                ("Рішення", w.get("decisions", []), bullet), ("Зобов'язання з нашого боку", w.get("commitments", []), bullet),
                ("Нові вимоги (кандидати на зміну обсягу)", w.get("new_requests", []), bullet),
                ("Відкриті питання", w.get("open_questions", []), bullet), ("Ризики", w.get("risks", []), bullet)]
    for title, items, kind in sections:
        items = [i for i in items if str(i).strip(" :")]
        if items:
            b.append(h(3, title))
            b += [kind(str(i)) for i in items]
    tips = stats.get("tips", {})
    tr = stats.get("transcript", {})
    b.append(h(3, "Live Tips"))
    b.append(bullet(f"Підказки: показано {tips.get('shown', 0)}, карток {tips.get('cards_fired', 0)}, фактів {tips.get('facts_shown', 0)}, "
                    f"запізнілих {tips.get('late', 0)}; затримка медіана {tips.get('delay_median_s', '?')} с, макс {tips.get('delay_max_s', '?')} с"))
    b.append(bullet("Підготовка з Cowork: " + ("використана" if prep_used else "не було")))
    b.append(bullet(f"Транскрипт: {tr.get('lines_real', '?')} рядків, мови {', '.join((tr.get('langs') or {}).keys())}, локальний файл {md.name}"))
    return b


# ---------------------------------------------------------------- Notion
def upload_md(name: str, text: str) -> str:
    fu = notion("POST", "/file_uploads", {"filename": name, "content_type": "text/markdown"})
    boundary = "----lt" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: text/markdown\r\n\r\n").encode() + text.encode("utf-8") + f"\r\n--{boundary}--\r\n".encode()
    tok = os.environ.get("NOTION_TOKEN", "")
    http("POST", fu["upload_url"], {"Authorization": f"Bearer {tok}", "Notion-Version": NOTION_VERSION},
         raw=body, ctype=f"multipart/form-data; boundary={boundary}")
    return fu["id"]


def file_block(upload_id: str, name: str) -> dict:
    return {"type": "file", "file": {"type": "file_upload", "file_upload": {"id": upload_id}, "name": name}}


def find_page(ds: str, start: dt.datetime) -> dict | None:
    lo, hi = (start - dt.timedelta(minutes=20)).isoformat(), (start + dt.timedelta(minutes=20)).isoformat()
    r = notion("POST", f"/data_sources/{ds}/query", {"filter": {"and": [
        {"property": "Date", "date": {"on_or_after": lo}}, {"property": "Date", "date": {"on_or_before": hi}}]},
        "page_size": 10})
    pages = r.get("results", [])
    if not pages:
        return None

    def gap(p):
        s = ((p.get("properties", {}).get("Date") or {}).get("date") or {}).get("start")
        try:
            return abs((dt.datetime.fromisoformat(s.replace("Z", "+00:00")) - start).total_seconds())
        except Exception:  # noqa: BLE001
            return 1e9
    return sorted(pages, key=gap)[0]


def append(page_id: str, blocks: list) -> None:
    for i in range(0, len(blocks), 90):
        notion("PATCH", f"/blocks/{page_id}/children", {"children": blocks[i:i + 90]})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--project-config", required=True, type=Path)
    ap.add_argument("--lt", nargs=2, required=True)
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--find-only", action="store_true", help="only look up this meeting's page in Notion")
    a = ap.parse_args(argv)
    res = {"ok": False, "url": None, "created": False, "error": None}
    try:
        ids = config_ids(a.project_config)
        if not ids.get("meetings_db"):
            raise RuntimeError(f"no meetings_db in {a.project_config.name}")
        if a.find_only:
            p = find_page(ids["meetings_db"], header_info(a.md)["start"])
            print(json.dumps({"ok": True, "found": bool(p), "url": p and p.get("url")}))
            return 0
        out = subprocess.run(list(a.lt) + ["wrapup-data", str(a.md)], capture_output=True, text=True, timeout=120).stdout
        stats = json.loads(out[out.find("{"):])
        clean = Path(stats["transcript"]["clean_file"]).read_text(encoding="utf-8")
        plain = re.sub(r"\\([][<>*_#])", r"\1", clean)
        if stats["transcript"].get("lines_real", 0) < 5:
            raise RuntimeError("fewer than 5 transcript lines: nothing to write")
        brief_f = Path(str(a.md)[:-3] + ".brief.md")
        brief = brief_f.read_text(encoding="utf-8") if brief_f.exists() else ""
        info = header_info(a.md)
        w = claude_wrapup(plain, brief, a.model)
        blocks = wrapup_blocks(w, stats, a.md, bool(brief))
        fname = a.md.stem + "-transcript.md"
        if a.dry_run:
            print(json.dumps({"ok": True, "dry_run": True, "name": w.get("name"), "summary": w.get("summary"),
                              "blocks": len(blocks), "ids": ids}, ensure_ascii=False))
            return 0
        up = upload_md(fname, plain)
        hhmm = dt.datetime.now().strftime("%H:%M")
        page = find_page(ids["meetings_db"], info["start"])
        if page:
            props = page.get("properties", {})
            upd = {}
            if ids.get("project_page_id") and not (props.get("Project") or {}).get("relation"):
                upd["Project"] = {"relation": [{"id": ids["project_page_id"]}]}
            if ids.get("workspace_page_id") and not (props.get("Workspace") or {}).get("relation"):
                upd["Workspace"] = {"relation": [{"id": ids["workspace_page_id"]}]}
            if upd:
                notion("PATCH", f"/pages/{page['id']}", {"properties": upd})
            append(page["id"], [h(2, f"Live Tips: підсумок і роздуми ({hhmm})"), para(w.get("summary", ""))] + blocks
                   + [h(3, "Транскрипт (Live Tips)"), file_block(up, fname)])
            res.update(ok=True, url=page.get("url"))
        else:
            start = info["start"]
            props = {"Meeting Name": {"title": rt((w.get("name") or info["title"]) + " ") + [
                        {"type": "mention", "mention": {"type": "date", "date": {"start": start.isoformat(timespec="minutes"),
                                                                                  "time_zone": None}}}]},
                     "Date": {"date": {"start": start.isoformat(timespec="seconds")}},
                     "Summary": {"rich_text": rt(w.get("summary", ""))}}
            props["Meeting Name"]["title"][-1]["mention"]["date"].pop("time_zone")
            if ids.get("project_page_id"):
                props["Project"] = {"relation": [{"id": ids["project_page_id"]}]}
            if ids.get("workspace_page_id"):
                props["Workspace"] = {"relation": [{"id": ids["workspace_page_id"]}]}
            p = notion("POST", "/pages", {"parent": {"type": "data_source_id", "data_source_id": ids["meetings_db"]},
                                          "properties": props,
                                          "children": [h(2, "Підсумок")] + blocks + [h(2, "Транскрипт"), file_block(up, fname)]})
            res.update(ok=True, url=p.get("url"), created=True)
    except Exception as e:  # noqa: BLE001
        res["error"] = f"{type(e).__name__}: {e}"[:600]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
