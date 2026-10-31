"""Pacenote 0.8.8 (rules/decisions.yaml): decisions heard on a call go to the Control Tower Decisions database.

  python -m livetips_m0.decision_notion --db <data source id> --title "<decision>" [--call-file <transcript.md>]
       [--call "<title, date>"] [--source <meeting page url>] [--date YYYY-MM-DD] [--stated-by <name>]
       [--project-name N | --project-page ids] [--project-prop P] [--workspace-prop P --workspace-value V | --workspace-page ids]
       [--no-ai] [--no-supersede-check] [--dry-run]
  ... --from-call --call-file <md>            every decision of the call's last call picture not written yet
  ... --list-active                           the project's active decisions as JSON
  ... --snapshot <root>/pacenote/decisions.md the same list written for the preparation and the live engine
  ... --supersede <old page id> --new <new page id>   only after the PM's click: old Status = Superseded + links

The model (the app's "After the call" way) picks Area from the database's own options, writes one Context sentence
from the transcript and fills Trade-off, Alternatives rejected, Review trigger and Door only when they were said;
it never invents them. Without a model the decision is written with what is known. Needs NOTION_TOKEN (the app
passes it to the child only). Prints one JSON line {"ok", "url", "id", "error", ...}.
"""
import argparse
import datetime as dt
import json
import re
from pathlib import Path
from typing import List, Optional

from . import notion_links
from .wrapup_notion import add_link_args, apply_link_args, config_ids, link_prop, link_value, link_values, notion, page_ids, parse_object, rt

TEXT_PROPS = {"context": "Context", "stated_by": "Stated by", "trade_off": "Trade-off",
              "alternatives": "Alternatives rejected", "review_trigger": "Review trigger"}


# ---------------------------------------------------------------- schema
def find(props: dict, names, types) -> Optional[tuple]:
    """(name, type) of the first property whose name matches (any case) and whose type is allowed."""
    low = {n.lower(): n for n in props}
    for want in names:
        n = low.get(want.lower())
        if n and props[n].get("type") in types:
            return n, props[n]["type"]
    return None


def options(props: dict, p: Optional[tuple]) -> List[str]:
    if not p:
        return []
    inner = props[p[0]].get(p[1]) or {}
    return [o.get("name", "") for o in inner.get("options") or [] if o.get("name")]


def decision_schema(ds: str) -> dict:
    props = notion("GET", f"/data_sources/{ds}").get("properties", {})
    titles = [n for n, v in props.items() if v.get("type") == "title"]
    sc = {"props": props, "title": (titles or ["Decision"])[0],
          "date": find(props, ["Date", "Decided", "Decision date"], ("date",)),
          "area": find(props, ["Area"], ("select", "multi_select")),
          "source": find(props, ["Source", "Source url", "Link"], ("url", "rich_text")),
          "status": find(props, ["Status"], ("status", "select")),
          "door": find(props, ["Door"], ("select", "rich_text")),
          "supersedes": find(props, ["Supersedes"], ("relation",)),
          "superseded_by": find(props, ["Superseded By", "Superseded by"], ("relation",)),
          "project": link_prop(props, "Project")}
    for k, name in TEXT_PROPS.items():
        sc[k] = find(props, [name], ("rich_text",))
    sc["area_options"], sc["door_options"] = options(props, sc["area"]), options(props, sc["door"])
    return sc


def put_text(out: dict, p: Optional[tuple], value: str) -> None:
    if p and value:
        out[p[0]] = {"rich_text": rt(value[:1900])}


def put_choice(out: dict, p: Optional[tuple], value: str, allowed: List[str]) -> None:
    """A select or multi-select only takes one of the database's own options (never a new one)."""
    if not p or not value:
        return
    if p[1] == "rich_text":
        put_text(out, p, value)
        return
    hit = next((o for o in allowed if o.lower() == value.strip().lower()), None)
    if hit:
        out[p[0]] = {"select": {"name": hit}} if p[1] == "select" else {"multi_select": [{"name": hit}]}


def decision_props(sc: dict, title: str, d: dict, ids: dict, project_name: str, workspace_value: str) -> dict:
    props = {sc["title"]: {"title": rt(title)}}
    if sc["date"] and d.get("date"):
        props[sc["date"][0]] = {"date": {"start": d["date"]}}
    put_choice(props, sc["area"], d.get("area", ""), sc["area_options"])
    put_choice(props, sc["door"], d.get("door", ""), sc["door_options"])
    for k in TEXT_PROPS:
        put_text(props, sc[k], d.get(k, ""))
    if sc["source"] and d.get("source"):
        props[sc["source"][0]] = {"url": d["source"]} if sc["source"][1] == "url" else {"rich_text": rt(d["source"])}
    if sc["status"]:
        props[sc["status"][0]] = {sc["status"][1]: {"name": "Active"}}
    props.update(link_values(sc["props"], ids, project_name, workspace_value))
    return props


# ---------------------------------------------------------------- the model
SYSTEM = """You fill the register entry of one decision made on a work call, from the call transcript.
Return ONLY one JSON object: {"area": "", "context": "", "stated_by": "", "trade_off": "", "alternatives": "",
"review_trigger": "", "door": ""}.
- area: exactly one of AREA OPTIONS that fits, else "".
- context: one short sentence, from the transcript, on why or in what situation it was decided.
- stated_by: the name of the person who said or confirmed the decision, when the transcript shows it, else "".
- trade_off, alternatives (the options rejected), review_trigger (when to look at it again), door (one of DOOR
  OPTIONS: one-way or two-way): ONLY when said outright on the call; otherwise "". Never invent them.
Write in the language of the decision. No long dashes. Inside text use « » for quotes."""


def model_details(decision: str, transcript: str, sc: dict, model: str, provider=None) -> dict:
    from .routing import provider_from_env
    prov = provider or provider_from_env("after", timeout=90.0)
    user = ("DECISION: {}\nAREA OPTIONS: {}\nDOOR OPTIONS: {}\n\nTRANSCRIPT:\n{}".format(
        decision, ", ".join(sc["area_options"]) or "(none)", ", ".join(sc["door_options"]) or "(none)", transcript[:60000]))
    c = prov.complete(model=model, system=[{"text": SYSTEM}], user=user, max_tokens=500, cache_ttl=None)
    if c.error:
        raise RuntimeError(str(c.error)[:200])
    o = parse_object(c.text)
    return {k: str(o.get(k) or "").replace(chr(0x2014), "-").strip() for k in ("area", "door", *TEXT_PROPS)}


CONFLICT = """Does the NEW decision replace (contradict or reverse) one of the ACTIVE decisions of the same project?
Only a real contradiction, not a related topic or a refinement. Return ONLY {"replaces": <number of the active
decision or -1>}."""


def supersede_candidate(new: str, active: List[dict], model: str, provider=None) -> Optional[dict]:
    if not active:
        return None
    from .routing import provider_from_env
    prov = provider or provider_from_env("after", timeout=60.0)
    user = "NEW: {}\n\nACTIVE:\n{}".format(new, "\n".join("{}. {} ({})".format(i, d["title"], d.get("date", "")) for i, d in enumerate(active)))
    c = prov.complete(model=model, system=[{"text": CONFLICT}], user=user, max_tokens=60, cache_ttl=None)
    if c.error:
        return None
    try:
        n = int(parse_object(c.text).get("replaces", -1))
    except (ValueError, TypeError):
        return None
    return active[n] if 0 <= n < len(active) else None


# ---------------------------------------------------------------- reading the register
def project_filter(sc: dict, ids: dict, project_name: str) -> Optional[dict]:
    """A query filter for the project's pages; None when the database has no project property to filter by."""
    p = sc["project"]
    if not p:
        return None
    name, t = p
    pids = page_ids(ids.get("project_page_id"))
    if t == "relation" and pids:
        ors = [{"property": name, "relation": {"contains": x}} for x in pids]
        return ors[0] if len(ors) == 1 else {"or": ors}
    if not project_name:
        return None
    vals = [v.strip() for v in project_name.split(",") if v.strip()]
    key = {"select": "equals", "multi_select": "contains", "rich_text": "contains"}.get(t)
    if not key:
        return None
    ors = [{"property": name, t: {key: v}} for v in vals]
    return ors[0] if len(ors) == 1 else {"or": ors}


def plain(v: dict) -> str:
    t = v.get("type")
    if t in ("title", "rich_text"):
        return "".join(x.get("plain_text") or (x.get("text") or {}).get("content", "") for x in v.get(t) or [])
    if t in ("select", "status"):
        return (v.get(t) or {}).get("name", "")
    if t == "multi_select":
        return ", ".join(o.get("name", "") for o in v.get(t) or [])
    if t == "date":
        return ((v.get("date") or {}).get("start") or "")[:10]
    if t == "url":
        return v.get("url") or ""
    return ""


def list_active(ds: str, sc: dict, ids: dict, project_name: str, limit: int = 30) -> List[dict]:
    pf = project_filter(sc, ids, project_name)
    if sc["project"] and not pf:
        return []              # the database is per project but this project has no value: never another project's
    flt = [pf] if pf else []
    if sc["status"]:
        flt.append({"property": sc["status"][0], sc["status"][1]: {"equals": "Active"}})
    body = {"page_size": min(100, limit)}
    if flt:
        body["filter"] = flt[0] if len(flt) == 1 else {"and": flt}
    if sc["date"]:
        body["sorts"] = [{"property": sc["date"][0], "direction": "descending"}]
    out = []
    for pg in notion("POST", f"/data_sources/{ds}/query", body).get("results", [])[:limit]:
        pr = pg.get("properties", {})
        get = lambda p: plain(pr.get(p[0]) or {}) if p else ""  # noqa: E731
        out.append({"id": pg.get("id", ""), "url": pg.get("url", ""), "title": plain(pr.get(sc["title"]) or {}),
                    "date": get(sc["date"]) or (pg.get("created_time") or "")[:10], "stated_by": get(sc["stated_by"]),
                    "area": get(sc["area"])})
    return out


def snapshot_text(active: List[dict], when: str) -> str:
    """rules/decisions.yaml > snapshot: one line per active decision, newest first."""
    head = ["# Active decisions", "", "Snapshot of the Notion Decisions register, taken {}. Read by Pacenote; do not edit.".format(when), ""]
    rows = ["- {} | {} | {} | {}".format(d.get("date", ""), d.get("title", "").replace("|", "/").replace("\n", " "),
                                         d.get("stated_by", "").replace("|", "/"), d.get("area", "").replace("|", "/"))
            for d in active if d.get("title")]
    return "\n".join(head + rows) + "\n"


def parse_snapshot(text: str) -> List[dict]:
    """The lines of a decisions.md snapshot (the live engine and the tests read the same format)."""
    out = []
    for ln in (text or "").splitlines():
        if not ln.startswith("- "):
            continue
        parts = [p.strip() for p in ln[2:].split("|")]
        if len(parts) >= 2 and parts[1]:
            out.append({"date": parts[0], "title": parts[1], "stated_by": parts[2] if len(parts) > 2 else "",
                        "area": parts[3] if len(parts) > 3 else ""})
    return out


# ---------------------------------------------------------------- writing
def call_decisions(md: Path) -> List[str]:
    from .callinfo import last_item
    sit = last_item(md, "situation") or {}
    return [str(x).strip() for x in sit.get("decisions") or [] if str(x).strip()]


def transcript_of(md: Optional[Path]) -> str:
    if not md or not md.exists():
        return ""
    from .callinfo import transcript_text
    return transcript_text(md)


def call_date(md: Optional[Path]) -> str:
    if md and md.exists():
        m = re.match(r"^(\d{4}-\d\d-\d\d)", md.name)
        if m:
            return m.group(1)
    return dt.date.today().isoformat()


def write_one(a, db: str, sc: dict, ids: dict, title: str, transcript: str, check: bool) -> dict:
    title = title.replace(chr(0x2014), "-").strip()[:200]
    had = notion_links.get(a.call_file, "decisions", title)
    if had:
        return {"ok": True, "url": had.get("url"), "id": had.get("id"), "existing": True}
    d = {"date": a.date or call_date(Path(a.call_file) if a.call_file else None), "source": a.source}
    if not a.no_ai and transcript:
        try:
            d.update({k: v for k, v in model_details(title, transcript, sc, a.model).items() if v})
        except Exception as e:  # noqa: BLE001  (a decision without its details is still written)
            d["_ai_error"] = str(e)[:120]
    if a.stated_by:
        d["stated_by"] = a.stated_by
    body = [{"type": "paragraph", "paragraph": {"rich_text": rt("Decided on the call: " + a.call)}}] if a.call else []
    page = notion("POST", "/pages", {"parent": {"type": "data_source_id", "data_source_id": db},
                                     "properties": decision_props(sc, title, d, ids, a.project_name, a.workspace_value),
                                     "children": body})
    notion_links.put(a.call_file, "decisions", title, page.get("id", ""), page.get("url", ""))
    out = {"ok": True, "url": page.get("url"), "id": page.get("id")}
    if check and not a.no_ai:
        try:
            active = [x for x in list_active(db, sc, ids, a.project_name) if x["id"] != page.get("id")]
            cand = supersede_candidate(title, active, a.model)
            if cand:
                out["supersede"] = {"id": cand["id"], "title": cand["title"], "date": cand.get("date", ""), "url": cand.get("url", "")}
        except Exception:  # noqa: BLE001
            pass
    return out


def supersede(sc: dict, old: str, new: str) -> dict:
    """rules/decisions.yaml > supersede: after the PM's click only."""
    if sc["status"]:
        notion("PATCH", f"/pages/{old}", {"properties": {sc["status"][0]: {sc["status"][1]: {"name": "Superseded"}}}})
    if sc["superseded_by"]:
        notion("PATCH", f"/pages/{old}", {"properties": {sc["superseded_by"][0]: {"relation": [{"id": new}]}}})
    if sc["supersedes"]:
        notion("PATCH", f"/pages/{new}", {"properties": {sc["supersedes"][0]: {"relation": [{"id": old}]}}})
    return {"ok": True}


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-config", type=Path)
    ap.add_argument("--db", default="")
    ap.add_argument("--title", default="")
    ap.add_argument("--call", default="")
    ap.add_argument("--call-file", default="")
    ap.add_argument("--source", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--stated-by", default="")
    ap.add_argument("--model", default="claude-haiku-5-5")
    ap.add_argument("--no-ai", action="store_true")
    ap.add_argument("--no-supersede-check", action="store_true")
    ap.add_argument("--from-call", action="store_true")
    ap.add_argument("--list-active", action="store_true")
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--supersede", default="")
    ap.add_argument("--new", default="")
    ap.add_argument("--dry-run", action="store_true")
    add_link_args(ap)
    return ap.parse_args(argv)


def decisions_db(a, ids: dict) -> str:
    db = (a.db or ids.get("decisions_db") or "").replace("collection://", "").strip()
    if not db:
        raise RuntimeError("no Decisions database: choose one in Settings > Integrations > Notion")
    return db


def run(a) -> dict:
    ids = config_ids(a.project_config) if a.project_config and a.project_config.exists() else {}
    apply_link_args(a, ids)
    db = decisions_db(a, ids)
    if a.dry_run:
        return {"ok": True, "dry_run": True, "db": db, "title": a.title.replace(chr(0x2014), "-").strip()[:200]}
    sc = decision_schema(db)
    if a.supersede:
        return supersede(sc, a.supersede, a.new)
    if a.list_active or a.snapshot:
        active = list_active(db, sc, ids, a.project_name)
        if a.snapshot:
            p = Path(a.snapshot)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(snapshot_text(active, dt.datetime.now().strftime("%Y-%m-%d %H:%M")), encoding="utf-8")
        return {"ok": True, "n": len(active), "decisions": active if a.list_active else None}
    md = Path(a.call_file) if a.call_file else None
    transcript = transcript_of(md)
    if a.from_call:
        if not md:
            raise RuntimeError("--from-call needs --call-file")
        done = [write_one(a, db, sc, ids, t, transcript, False) for t in call_decisions(md)]
        new = [d for d in done if not d.get("existing")]
        return {"ok": True, "added": len(new), "skipped": len(done) - len(new), "url": new[0]["url"] if new else None}
    if not a.title.strip():
        raise RuntimeError("no decision text")
    return write_one(a, db, sc, ids, a.title, transcript, not a.no_supersede_check)


def main(argv=None) -> int:
    a = parse_args(argv)
    res = {"ok": False, "url": None, "error": None}
    try:
        res.update(run(a))
    except Exception as e:  # noqa: BLE001
        res["error"] = str(e)[:300]
    print(json.dumps({k: v for k, v in res.items() if v is not None or k in ("ok", "url", "error")}, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
