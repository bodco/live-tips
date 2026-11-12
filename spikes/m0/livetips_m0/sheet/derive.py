"""0.10.0 (Meeting Sheet, phase 3): the files the current live recorder reads, written from the sheet.

There is no separate brief any more: <base>.brief.md is a generated human copy of the sheet (the Brief tab and the
tips window keep working), with the agenda and the questions as the checklist ("- [ ] **topic:** ... <!-- agenda:ID -->",
the markers livetips_m0.agenda understands). <base>.cards.json, <base>.facts.json (recorder parse_cards /
parse_facts), <base>.slides.json for a deck source, <base>.agenda.json. Phase 7 makes the recorder read sheet.json
directly; these files stay the fallback.
"""
import json
import os
import re
from pathlib import Path
from typing import Dict, List, Optional

from . import readers

LIVE_FACTS = {"header", "company", "tech_stack", "contact", "history", "project_context", "action_items",
              "interview_candidate", "qualification", "red_lines", "signals", "fit", "overview", "best_outcome",
              "my_focus", "interview_role", "standup_since", "standup_today", "standup_blockers", "standup_waiting"}
# 0.10.0 (Meeting Sheet, round 2): questions live only in the questions checklist (the recorder's "questions" and
# "Ask now"); no keyword card of their own here
CARD_BLOCKS = {"my_focus": "yellow", "overview": "yellow", "signals": "yellow", "fit": "green", "best_outcome": "green",
               "interview_role": "yellow", "red_lines": "red"}
SHOWN = ("found", "conflict", "edited", "needs_check", "stale")


def _live(f: dict) -> bool:
    # 0.10.0 (Meeting Sheet, round 2): a value replaced by a newer one (superseded_by) never goes live
    return f.get("status") in SHOWN and not f.get("superseded_by")


def _was(sheet: dict, f: dict) -> str:
    """ (was: <older value>) for a fact that replaced an older one (newer wins, round 2)."""
    old = [x for b in sheet.get("blocks") or [] for x in b.get("facts") or [] if x.get("superseded_by") == f.get("id")]
    if not old:
        return ""
    t = old[0].get("text") or ""
    return f" ({_w('was')}: " + (t if len(t) <= 90 else t[:87].rstrip() + "...") + ")"


def _src_label(sheet: dict, ids: List[str]) -> str:
    by = {s["id"]: s for s in sheet.get("sources") or []}
    return "; ".join(f"[{by[i].get('n', '?')}] {by[i].get('title', '')}" for i in ids if i in by)


def _cite(sheet: dict, ids: List[str]) -> str:
    by = {s["id"]: s for s in sheet.get("sources") or []}
    ns = [str(by[i]["n"]) for i in ids if i in by]
    return (" [" + ", ".join(ns) + "]") if ns else ""


def _when(sheet: dict) -> str:
    s = (sheet.get("meeting_ref") or {}).get("start", "")
    return s[:16].replace("T", " ")


WORDS = {"en": {"conflict": "sources disagree", "stale": "old", "needs_check": "check", "not_found": "Not found",
                "goal": "Goal", "sources": "Sources", "owner": "owner", "lead": "lead", "none": "Not found yet.", "was": "was",
                "questions": "Questions to ask"},
         "uk": {"conflict": "джерела розходяться", "stale": "застаріло", "needs_check": "перевірити", "not_found": "Не знайдено",
                "goal": "Мета", "sources": "Джерела", "owner": "відповідальний", "lead": "веде", "none": "Поки нічого не знайдено.", "was": "було",
                "questions": "Питання"}}
_LANG = ["en"]


def _w(k: str) -> str:
    return WORDS.get(_LANG[0], WORDS["en"]).get(k, WORDS["en"][k])


def _mark(st: str) -> str:
    return f" ({_w(st)})" if st in ("conflict", "stale", "needs_check") else ""


def render_md(sheet: dict, for_brief: bool = False) -> str:
    """The sheet as Markdown: <base>.sheet.md, and the body of the derived brief."""
    title = sheet.get("title") or "Meeting Sheet"
    _LANG[0] = "uk" if str(sheet.get("language") or "en").startswith("uk") else "en"
    lines = []
    if for_brief:
        mt = re.sub(r"^Meeting Sheet:\s*", "", title)
        lines.append(f"# Live Brief: {mt} (prep, {_when(sheet)}, Meeting Sheet)")
        lines.append("")
        lines.append("> Generated from the Meeting Sheet (" + os.path.basename(sheet.get("id", "")) + "). Edit the sheet, "
                     "not this file: it is written again on every build.")
    else:
        lines.append(f"# {title}")
        lines.append("")
        rd = (sheet.get("readiness") or {}).get("state", "")
        lines.append(f"{_when(sheet)} · {sheet.get('preset', '')} · route {sheet.get('route', '')}" + (f" · readiness: {rd}" if rd else ""))
    if sheet.get("goal"):
        lines += ["", f"**{_w('goal')}:** {sheet['goal']}"]
    blocks = sorted([b for b in sheet.get("blocks") or [] if b.get("visible", True)], key=lambda b: b.get("order", 0))
    if for_brief:
        ess = []
        for t in ("overview", "my_focus", "best_outcome"):
            for b in blocks:
                if b["type"] == t:
                    ess += [f"- {f.get('label') + ': ' if f.get('label') else ''}{f['text']}" for f in b.get("facts") or [] if _live(f)][:4]
        if ess:
            lines += ["", "## Live essentials"] + ess[:10]
        check = checklist(sheet)
        if check:
            lines += ["", "## 1. Checklist"] + check
            dec = [f for b in blocks if b["type"] == "best_outcome" for f in b.get("facts") or [] if _live(f)]
            if dec:
                lines += ["", "**Decisions to obtain:** " + " ".join(f"({chr(97 + i)}) {f['text']}" for i, f in enumerate(dec[:6]))]
        qs = [f for b in blocks if b["type"] == "questions" for f in b.get("facts") or [] if _live(f)]
        if qs:
            # 0.10.0 (round 2): a plain list, not checkboxes: the window ticks them in the questions checklist only
            lines += ["", "## " + _w("questions")] + [f"- {f['text']}" for f in qs]
    for b in blocks:
        facts = b.get("facts") or []
        shown = [f for f in facts if _live(f) or f.get("status") == "not_found"]
        if not shown and b.get("only_if_data"):
            continue
        if for_brief and b["type"] in ("agenda", "questions"):
            continue
        head = b.get("title", b["type"]) + (f" ({str(b.get('method')).upper()})" if b.get("method") else "")
        lines += ["", f"## {head}"]
        if not shown:
            lines.append("- " + _w("none"))
        for f in shown:
            lab = f"**{f['label']}:** " if f.get("label") else ""
            lvl = (f.get("value") or {}).get("level")
            lvl = f" ({lvl})" if lvl else ""
            own = (f.get("value") or {}).get("owner")
            own = f" ({_w('owner')}: {own})" if own else ""
            nf = _w("not_found") + ": " if f.get("status") == "not_found" else ""
            lines.append(f"- {lab}{nf}{f['text']}{lvl}{own}{_mark(f.get('status', ''))}{_cite(sheet, f.get('source_ids') or [])}"
                         + ("" if for_brief else _was(sheet, f)))
    rd = sheet.get("readiness") or {}
    if rd.get("gaps") and not for_brief:
        lines += ["", f"## Readiness: {rd.get('state', '')}"] + [f"- {g.get('text', '')}" for g in rd["gaps"]]
    lines += ["", "## " + _w("sources")]
    for s in sheet.get("sources") or []:
        used = s.get("used", "")
        extra = f" ({used}" + (f": {s['reason']}" if s.get("reason") else "") + ")" if used and used != "full" else ""
        where = s.get("uri") or s.get("path") or ""
        lines.append(f"[{s.get('n')}] {s.get('title', '')}" + (f" - {where}" if where and where not in s.get("title", "") else "") + extra)
    return "\n".join(lines).rstrip() + "\n"


def agenda_id(f: dict) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "-", f.get("id", ""))[:80]


def checklist(sheet: dict) -> List[str]:
    out = []
    for b in sorted(sheet.get("blocks") or [], key=lambda b: b.get("order", 0)):
        if b["type"] != "agenda" or not b.get("visible", True):
            continue                     # 0.10.0 (round 2): the agenda block only; questions are their own checklist
        for f in b.get("facts") or []:
            if not _live(f):
                continue
            topic = f.get("label") or "Item"
            own = (f.get("value") or {}).get("owner")
            out.append(f"- [ ] **{topic}:** {f['text']}" + (f" ({_w('lead')}: {own})" if own else "") + f" <!-- agenda:{agenda_id(f)} -->")
    return out


def _keywords(f: dict) -> List[str]:
    kw = [k.lower() for k in f.get("keywords") or [] if len(k) >= 4]
    if not kw and f.get("label") and len(f["label"]) >= 4:
        kw = [f["label"].lower()]
    return kw[:6]


def cards(sheet: dict) -> List[dict]:
    out = []
    for b in sheet.get("blocks") or []:
        lvl = CARD_BLOCKS.get(b["type"])
        if not lvl:
            continue
        for f in b.get("facts") or []:
            trig = _keywords(f)
            if not _live(f) or not trig:
                continue
            c = {"id": "sh-" + f["id"][2:], "triggers": trig, "on": "them" if b["type"] != "questions" else "any",
                 "level": lvl, "gist": (f.get("label") + ": " if f.get("label") else "") + f["text"][:140],
                 "phrase": f["text"] if b["type"] == "questions" else "", "note": _src_label(sheet, f.get("source_ids") or []),
                 "cooldown_s": 300, "sheet_fact": f["id"]}
            if b["type"] == "red_lines":
                c["note"] = ("Red line. " + c["note"]).strip()
            out.append(c)
    return out


def facts(sheet: dict) -> List[dict]:
    out = []
    for b in sheet.get("blocks") or []:
        if b["type"] not in LIVE_FACTS:
            continue
        for f in b.get("facts") or []:
            if not _live(f):
                continue
            g = {"id": "sh-" + f["id"][2:], "title": f.get("label") or b.get("title", b["type"]), "text": f["text"],
                 "keywords": _keywords(f), "source": _src_label(sheet, f.get("source_ids") or []) or "Meeting Sheet",
                 "sheet_fact": f["id"], "block": b["type"]}
            if f.get("status") in ("conflict", "stale", "needs_check"):
                g["status"] = f["status"]
            if b["type"] == "red_lines":
                g["red_line"] = True
            out.append(g)
    return out


def slides(sheet: dict) -> Optional[dict]:
    """A deck source (deck: {owners, minutes, qa_minutes}) read as slides; owners other than ours are "other"."""
    deck = next((s for s in sheet.get("sources") or [] if s.get("deck") and (s.get("path") or s.get("copy"))), None)
    if not deck:
        return None
    r = readers.read(deck.get("copy") or deck["path"])
    sl = r.get("slides")
    if not sl and deck.get("deck_json"):            # the app's own reading of the deck (Keynote, PDF via PDFKit)
        try:
            dj = json.loads(Path(os.path.expanduser(deck["deck_json"])).read_text(encoding="utf-8"))
            sl = [{"n": int(x.get("n", i + 1)), "title": x.get("title", ""), "text": x.get("text", "")}
                  for i, x in enumerate(dj.get("slides") or []) if isinstance(x, dict)]
        except (OSError, ValueError, TypeError):
            sl = None
    if not sl and r.get("text"):
        sl = [{"n": i + 1, "title": (p.strip().splitlines() or [""])[0][:80], "text": p} for i, p in
              enumerate(re.split(r"\n?\[page \d+\]\n", r["text"])) if p.strip()]
    if not sl:
        return None
    info = deck.get("deck") if isinstance(deck.get("deck"), dict) else {}
    owners = {str(k): v for k, v in (info.get("owners") or {}).items()}
    ours = [p.get("name", "") for p in (sheet.get("participants") or {}).get("ours") or []]
    me = ours[0] if ours else ""
    minutes = float(info.get("minutes") or 0)
    sec = int(minutes * 60 / max(1, len(sl))) if minutes else 60
    out = []
    for s in sl:
        o = owners.get(str(s["n"]), "")
        # the app's DeckSetup owners: "me", "all" (shared) or a colleague's name; missing = me
        who = "me" if (not o or o in ("me", me)) else "shared" if o == "all" else "other"
        o = me if who == "me" else ("" if who == "shared" else o)
        body = [{"k": "p", "t": t} for t in (s.get("text") or "").split("\n") if t.strip()][:4]
        out.append({"n": s["n"], "title": s.get("title") or f"Slide {s['n']}", "who": who, "speaker": o or me,
                    "sec": max(5, sec), "body": body, "numbers": [], "qa": [], "short": (s.get("text") or "")[:200]})
    res = {"slides": out}
    if minutes:
        res["talk_min"] = minutes
    if info.get("qa_minutes"):
        res["qa_min"] = info["qa_minutes"]
    return res


def derive(sheet: dict, base: str) -> List[str]:
    """Writes the live files next to the sheet; returns the paths written."""
    written = []
    def put(suffix, obj):
        p = base + suffix
        Path(p).parent.mkdir(parents=True, exist_ok=True)
        if isinstance(obj, str):
            Path(p).write_text(obj, encoding="utf-8")
        else:
            Path(p).write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
        written.append(p)
    put(".brief.md", render_md(sheet, for_brief=True))
    put(".cards.json", cards(sheet))
    put(".facts.json", facts(sheet))
    ag = [{"id": agenda_id(f), "text": f["text"], "label": f.get("label", ""), "owner": (f.get("value") or {}).get("owner", ""),
           "kind": b["type"]} for b in sheet.get("blocks") or [] if b["type"] == "agenda"
          for f in b.get("facts") or [] if _live(f)]
    if ag:
        put(".agenda.json", ag)
    sl = slides(sheet)
    if sl:
        put(".slides.json", sl)
    return written
