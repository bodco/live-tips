"""Add one risk heard on a call to the project's Notion risk database (Pacenote 0.8, F6, idea 09;
rules/risks.yaml > after_call). The app runs it only after the PM confirms; it never runs by itself.

  python -m livetips_m0.risk_notion --project-config <projects/<slug>.md> --title "<risk>" [--call "<call title, date>"]
       [--db <data source id>] [--project-name <name>] [--dry-run]
Needs NOTION_TOKEN in the environment (the app passes it to the child only). Prints JSON {"ok", "url", "error"}.
"""
import argparse
import json
from pathlib import Path

from .wrapup_notion import config_ids, notion, para, rt


def risk_schema(ds: str) -> dict:
    props = notion("GET", f"/data_sources/{ds}").get("properties", {})
    by = lambda t: [n for n, v in props.items() if v.get("type") == t]  # noqa: E731
    out = {"title": (by("title") or ["Name"])[0], "project": None}
    t = (props.get("Project") or {}).get("type")
    if t in ("relation", "select", "rich_text"):
        out["project"] = ("Project", t)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-config", type=Path)
    ap.add_argument("--db", default="")
    ap.add_argument("--title", required=True)
    ap.add_argument("--call", default="")
    ap.add_argument("--project-name", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    res = {"ok": False, "url": None, "error": None}
    try:
        ids = config_ids(a.project_config) if a.project_config and a.project_config.exists() else {}
        db = (a.db or ids.get("risks_db") or "").replace("collection://", "").strip()
        if not db:
            raise RuntimeError("no risk database: add risks_db to the project config")
        title = a.title.replace(chr(0x2014), "-").strip()[:200]
        if a.dry_run:
            print(json.dumps({"ok": True, "dry_run": True, "db": db, "title": title}, ensure_ascii=False))
            return 0
        sc = risk_schema(db)
        props = {sc["title"]: {"title": rt(title)}}
        if sc["project"]:
            name, t = sc["project"]
            if t == "relation" and ids.get("project_page_id"):
                props[name] = {"relation": [{"id": ids["project_page_id"]}]}
            elif t == "select" and a.project_name:
                props[name] = {"select": {"name": a.project_name[:100]}}
            elif t == "rich_text" and a.project_name:
                props[name] = {"rich_text": rt(a.project_name)}
        body = [para("Heard on the call: " + a.call)] if a.call else []
        page = notion("POST", "/pages", {"parent": {"type": "data_source_id", "data_source_id": db}, "properties": props, "children": body})
        res.update(ok=True, url=page.get("url"))
    except Exception as e:  # noqa: BLE001
        res["error"] = str(e)[:300]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
