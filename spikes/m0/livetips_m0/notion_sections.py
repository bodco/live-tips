"""Pacenote 0.8.7 (E): edits on the call page go to the call's existing Notion page at once. Each edited section
(Decisions, Open questions, Risks, Action items, Agenda, Sales) is replaced in place: the bullets under its heading are archived and
the new ones are written after the heading. A section missing on the page is added at the end. Nothing else on the
page changes. The app runs this only after the PM saved an edit on the call page.

  python -m livetips_m0.notion_sections --page <page id or url> --sections '<json {"Decisions": ["..."], ...}>'
"""
from __future__ import annotations

import argparse
import json
import re
import sys

from .wrapup_notion import TXT, bullet, h, notion, todo

HEADINGS = ("heading_1", "heading_2", "heading_3")


def text_of(b: dict) -> str:
    t = b.get("type", "")
    return "".join(x.get("plain_text", "") or (x.get("text") or {}).get("content", "") for x in (b.get(t) or {}).get("rich_text", []))


def plan(blocks: list, sections: dict, todo_sections: tuple = ()) -> dict:
    """Pure: what to archive and what to write for each section. blocks are the page's top-level blocks in order.
    Returns {"archive": [ids], "after": [(block_id, [new blocks])], "append": [new blocks], "appended": [headings]}.
    0.8.7 (E5): "appended" names the sections the page did not have, so the app can say they went to the end."""
    out = {"archive": [], "after": [], "append": [], "appended": []}
    norm = lambda s: re.sub(r"\s+", " ", s).strip().lower()  # noqa: E731
    for title, items in sections.items():
        items = [str(i).strip() for i in items if str(i).strip()]
        make = todo if title in todo_sections else bullet
        new = [make(i) for i in items]
        idx = next((i for i, b in enumerate(blocks) if b.get("type") in HEADINGS and norm(text_of(b)) == norm(title)), None)
        if idx is None:
            if new:
                out["append"] += [h(3, title)] + new
                out["appended"].append(title)
            continue
        j = idx + 1
        while j < len(blocks) and blocks[j].get("type") not in HEADINGS and blocks[j].get("type") != "divider":
            out["archive"].append(blocks[j]["id"])
            j += 1
        if new:
            out["after"].append((blocks[idx]["id"], new))
    return out


def titled(blocks: list, sections: dict, lang: str = "") -> dict:
    """Section ids (decisions, open, risks, actions) to the page's own headings: the language whose headings the page
    has wins, else `lang`, else English. Keys that are not ids pass through as headings."""
    T = TXT[page_lang(blocks, sections, lang)]
    return {T.get(k, k): v for k, v in sections.items()}


def page_lang(blocks: list, keys, lang: str = "") -> str:
    """The language whose headings the page has, else `lang`, else English."""
    have = {text_of(b).strip().lower() for b in blocks if b.get("type") in HEADINGS}
    langs = [l for l in TXT if any(TXT[l].get(k, "").lower() in have for k in keys if k != "sales")]
    return langs[0] if langs else (lang if lang in TXT else "en")


def with_sales(sections: dict, call_md: str, lang: str) -> dict:
    """0.8.7 (H6.1): the Sales section's lines come from <stem>.sales.json, written as the wrap-up writes them."""
    if "sales" not in sections or not call_md:
        return sections
    from pathlib import Path
    from .wrapup_notion import sales_lines
    return dict(sections, sales=sales_lines(Path(call_md), TXT[lang]))


def page_id(s: str) -> str:
    m = re.findall(r"[0-9a-fA-F]{32}|[0-9a-fA-F-]{36}", s or "")
    return m[-1].replace("-", "") if m else ""


def children(pid: str) -> list:
    out, cur = [], None
    while True:
        r = notion("GET", f"/blocks/{pid}/children?page_size=100" + (f"&start_cursor={cur}" if cur else ""))
        out += r.get("results", [])
        if not r.get("has_more"):
            return out
        cur = r.get("next_cursor")


def apply(pid: str, p: dict) -> None:
    for bid in p["archive"]:
        notion("DELETE", f"/blocks/{bid}")
    for after, new in p["after"]:
        notion("PATCH", f"/blocks/{pid}/children", {"children": new, "after": after})
    if p["append"]:
        notion("PATCH", f"/blocks/{pid}/children", {"children": p["append"]})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", required=True)
    ap.add_argument("--sections", required=True, help="JSON object: heading -> list of lines")
    ap.add_argument("--todo", default="", help="comma-separated headings written as to-dos")
    ap.add_argument("--lang", default="", help="the page's language when no heading tells it (uk or en)")
    ap.add_argument("--call-md", default="", help="0.8.7: the call's transcript; the sales section is read from <stem>.sales.json")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    res = {"ok": False, "error": None}
    try:
        pid = page_id(a.page)
        if not pid:
            raise RuntimeError("no Notion page for this call yet")
        blocks = children(pid)
        raw = json.loads(a.sections)
        secs = titled(blocks, with_sales(raw, a.call_md, page_lang(blocks, raw, a.lang)), a.lang)
        T = TXT.get(a.lang, TXT["en"])
        p = plan(blocks, secs, tuple(T.get(t, t) for t in a.todo.split(",") if t))
        if not a.dry_run:
            apply(pid, p)
        res.update(ok=True, archived=len(p["archive"]), written=sum(len(n) for _, n in p["after"]) + len(p["append"]),
                   appended=p["appended"])
    except Exception as e:  # noqa: BLE001
        res["error"] = str(e)[:300]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
