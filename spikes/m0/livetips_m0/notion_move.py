"""0.10.1 (A3, roadmap p.9): a call moved to another project; its Notion pages follow it.

  python -m livetips_m0.notion_move --kind meetings --md <moved transcript> [--page <id or url>]
      [--from-config <old projects/<slug>.md>] [--from-meetings-db <ds>] [--meetings-db <ds>] <link args of the new project>
  python -m livetips_m0.notion_move --kind decisions|risks --md <moved transcript> <link args of the new project>
  python -m livetips_m0.notion_move --moved-to <new page url> --page <old page id or url> [--lang en|uk]

meetings: the call's page (given, else found by the call's start in the old database) gets the new Project and
Workspace on the same page. When the new project's Meetings database is another one, nothing is changed and the
answer says other_db: the app asks the PM before it writes a new page there (a new summary costs a model call).
decisions, risks: the pages this call made (<stem>.notion.json) get the new Project and Workspace in place.
--moved-to: the old page gets one "Moved to <url>" paragraph.
Unlike the wrap-up, the values are overwritten: the page was linked to the old project. A new target without a value
(a workspace call, no page id) clears the property. Prints one JSON line. Env: NOTION_TOKEN.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from . import notion_links
from .wrapup_notion import (add_link_args, apply_link_args, config_ids, find_page, header_info, link_prop, link_value,
                            notion, rt)

TXT = {"en": "Moved to ", "uk": "Перенесено в: "}


def page_id(v: str) -> str:
    """A page id from an id or a Notion url (the last 32 hex digits), dashes dropped."""
    s = (v or "").strip().split("?")[0]
    m = re.findall(r"[0-9a-fA-F]{32}", s.replace("-", ""))
    return m[-1].lower() if m else ""


def norm_ds(v: str) -> str:
    return (v or "").replace("collection://", "").replace("-", "").strip().lower()


def cleared(t: str) -> dict:
    return {"relation": []} if t == "relation" else {"select": None} if t == "select" else {t: []}


def overwrite(props: dict, ids: dict, project_name: str, workspace_value: str) -> dict:
    """Project and Workspace of a page that moved: the new value, or empty when the new target has none."""
    out = {}
    for key, idkey, val in (("Project", "project_page_id", project_name), ("Workspace", "workspace_page_id", workspace_value)):
        lp = link_prop(props, key)
        if not lp:
            continue
        name, t = lp
        out[name] = link_value(name, t, ids.get(idkey), val).get(name) or cleared(t)
    return out


def parent_ds(page: dict) -> str:
    p = page.get("parent") or {}
    return norm_ds(p.get("data_source_id") or p.get("database_id") or "")


def move_page(pid: str, ids: dict, a) -> dict:
    """Overwrites Project and Workspace on one page in its own database."""
    page = notion("GET", f"/pages/{pid}")
    ds = (page.get("parent") or {}).get("data_source_id") or ""
    props = notion("GET", f"/data_sources/{ds}").get("properties", {}) if ds else {}
    upd = overwrite(props, ids, a.project_name, a.workspace_value)
    if upd:
        notion("PATCH", f"/pages/{pid}", {"properties": upd})
    return {"id": pid, "url": page.get("url"), "props": sorted(upd)}


def run_meetings(a, ids: dict) -> dict:
    target = norm_ds(a.meetings_db or ids.get("meetings_db", ""))
    pid = page_id(a.page)
    if not pid:
        old = norm_ds(a.from_meetings_db) or norm_ds(config_ids(Path(a.from_config)).get("meetings_db", "")
                                                     if a.from_config and Path(a.from_config).exists() else "") or target
        if not old:
            return {"ok": True, "found": False, "updated": 0}
        from .wrapup_notion import schema
        p = find_page(old, header_info(Path(a.md))["start"], schema(old)["date"])
        if not p:
            return {"ok": True, "found": False, "updated": 0}
        pid = page_id(p["id"])
    page = notion("GET", f"/pages/{pid}")
    if not target:
        return {"ok": True, "found": True, "updated": 0, "url": page.get("url"), "note": "no target database"}
    if parent_ds(page) != target:
        return {"ok": True, "found": True, "other_db": True, "page_id": pid, "url": page.get("url"), "updated": 0}
    r = move_page(pid, ids, a)
    return {"ok": True, "found": True, "updated": 1, "url": r["url"], "page_id": pid}


def run_items(a, ids: dict) -> dict:
    links = notion_links.load(a.md).get(a.kind) or {}
    done, errors = [], []
    for v in links.values():
        pid = page_id((v or {}).get("id", ""))
        if not pid:
            continue
        try:
            done.append(move_page(pid, ids, a)["id"])
        except Exception as e:  # noqa: BLE001 (one page failing does not stop the others)
            errors.append(str(e)[:200])
    return {"ok": not errors, "updated": len(done), "error": "; ".join(errors) or None}


def run_moved_to(a) -> dict:
    pid = page_id(a.page)
    if not pid:
        return {"ok": False, "error": "no page"}
    text = TXT.get(a.lang, TXT["en"])
    notion("PATCH", f"/blocks/{pid}/children", {"children": [{"object": "block", "type": "paragraph", "paragraph": {
        "rich_text": rt(text) + [{"type": "text", "text": {"content": a.moved_to, "link": {"url": a.moved_to}}}]}}]})
    return {"ok": True, "updated": 1}


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", default="meetings", choices=("meetings", "decisions", "risks"))
    ap.add_argument("--md", default="", help="the moved transcript (its new path)")
    ap.add_argument("--page", default="", help="the call's meeting page (id or url), when it is known")
    ap.add_argument("--project-config", default="", help="the new project's config")
    ap.add_argument("--meetings-db", default="", help="the one Meetings database chosen in Settings (F3)")
    ap.add_argument("--from-config", default="", help="the old project's config, to find the page")
    ap.add_argument("--from-meetings-db", default="", help="the old Meetings database, to find the page")
    ap.add_argument("--moved-to", default="", help="append 'Moved to <url>' to --page")
    ap.add_argument("--lang", default="en")
    add_link_args(ap)
    return ap.parse_args(argv)


def main(argv=None) -> int:
    a = parse_args(argv)
    res = {"ok": False, "kind": a.kind, "updated": 0, "error": None}
    try:
        if a.moved_to:
            res.update(run_moved_to(a))
        else:
            ids = config_ids(Path(a.project_config)) if a.project_config and Path(a.project_config).exists() else {}
            apply_link_args(a, ids)
            res.update(run_meetings(a, ids) if a.kind == "meetings" else run_items(a, ids))
    except Exception as e:  # noqa: BLE001
        res["ok"], res["error"] = False, str(e)[:400]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
