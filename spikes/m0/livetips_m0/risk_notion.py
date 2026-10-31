"""Add one risk heard on a call to the project's Notion risk database (Pacenote 0.8, F6, idea 09;
rules/risks.yaml > after_call). The app runs it after the PM confirms, or (0.8.8) after the call when the PM turned on
"Add automatically after each call" under Risks; it never runs by itself otherwise.

  python -m livetips_m0.risk_notion --project-config <projects/<slug>.md> --title "<risk>" [--call "<call title, date>"]
       [--db <data source id>] [--project-name <name>] [--workspace-prop P --workspace-value V | --workspace-page ids]
       [--call-file <transcript.md>] [--from-call] [--dry-run]
--call-file keeps the page next to the call (<stem>.notion.json) so the same risk of the same call is written once;
--from-call writes every risk of the call's last call picture that is not written yet (the automatic add).
Needs NOTION_TOKEN in the environment (the app passes it to the child only). Prints JSON {"ok", "url", "error"}.
"""
import argparse
import json
from pathlib import Path

from . import notion_links
from .wrapup_notion import add_link_args, apply_link_args, config_ids, link_prop, link_values, notion, para, rt


def risk_schema(ds: str) -> dict:
    props = notion("GET", f"/data_sources/{ds}").get("properties", {})
    titles = [n for n, v in props.items() if v.get("type") == "title"]
    return {"title": (titles or ["Name"])[0], "project": link_prop(props, "Project"), "props": props}


def risk_props(sc: dict, title: str, ids: dict, project_name: str, workspace_value: str = "") -> dict:
    props = {sc["title"]: {"title": rt(title)}}
    props.update(link_values(sc.get("props") or ({sc["project"][0]: {"type": sc["project"][1]}} if sc.get("project") else {}),
                             ids, project_name, workspace_value))
    return props


def risk_db(a, ids: dict) -> str:
    db = (a.db or ids.get("risks_db") or "").replace("collection://", "").strip()
    if not db:
        raise RuntimeError("no risk database: choose one in Settings > Integrations > Notion")
    return db


def call_risks(md: Path) -> list:
    """The risks of the call's last call picture (the call page's edits included)."""
    from .callinfo import last_item
    sit = last_item(md, "situation") or {}
    return [str(r.get("what") if isinstance(r, dict) else r).strip() for r in sit.get("risks") or []
            if str(r.get("what") if isinstance(r, dict) else r).strip()]


def write_one(a, db: str, sc: dict, ids: dict, title: str) -> dict:
    title = title.replace(chr(0x2014), "-").strip()[:200]
    had = notion_links.get(a.call_file, "risks", title)
    if had:
        return {"ok": True, "url": had.get("url"), "id": had.get("id"), "existing": True}
    props = risk_props(sc, title, ids, a.project_name, a.workspace_value)
    body = [para("Heard on the call: " + a.call)] if a.call else []
    page = notion("POST", "/pages", {"parent": {"type": "data_source_id", "data_source_id": db}, "properties": props, "children": body})
    notion_links.put(a.call_file, "risks", title, page.get("id", ""), page.get("url", ""))
    return {"ok": True, "url": page.get("url"), "id": page.get("id")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-config", type=Path)
    ap.add_argument("--db", default="")
    ap.add_argument("--title", default="")
    ap.add_argument("--call", default="")
    ap.add_argument("--call-file", default="", help="0.8.8: the transcript; pages are kept in <stem>.notion.json")
    ap.add_argument("--from-call", action="store_true", help="0.8.8: every risk of the call not written yet")
    add_link_args(ap)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    res = {"ok": False, "url": None, "error": None}
    try:
        ids = config_ids(a.project_config) if a.project_config and a.project_config.exists() else {}
        apply_link_args(a, ids)
        db = risk_db(a, ids)
        titles = call_risks(Path(a.call_file)) if a.from_call and a.call_file else [a.title]
        titles = [t for t in titles if t.strip()]
        if not titles:
            raise RuntimeError("no risk to add")
        if a.dry_run:
            print(json.dumps({"ok": True, "dry_run": True, "db": db, "title": titles[0].replace(chr(0x2014), "-").strip()[:200],
                              "n": len(titles)}, ensure_ascii=False))
            return 0
        sc = risk_schema(db)
        if a.from_call:
            done = [write_one(a, db, sc, ids, t) for t in titles]
            new = [d for d in done if not d.get("existing")]
            res.update(ok=True, added=len(new), skipped=len(done) - len(new), url=new[0]["url"] if new else None)
        else:
            res.update(write_one(a, db, sc, ids, titles[0]))
    except Exception as e:  # noqa: BLE001
        res["error"] = str(e)[:300]
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
