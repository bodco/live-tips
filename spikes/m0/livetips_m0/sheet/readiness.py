"""0.10.0 (Meeting Sheet, phase 1): readiness of a sheet by the rules of its preset (rules/meeting-sheet.yaml).

evaluate(sheet, rules) -> {state: ready|almost|not_ready, gaps: [...], checks: [...], dropped: [...]}, pure.
apply(sheet, rules) first adds (or takes back) the automatic questions, marks old facts stale, then evaluates and
stores the result in sheet["readiness"].
A blocker gap = not_ready, warnings only = almost, no gaps = ready. readiness.dropped (rule ids or gap ids) are the
checks the user dropped for this meeting: they count as passed.
"""
import calendar
import datetime as _dt
from typing import Dict, Iterable, List, Optional, Set, Tuple, Union

from .presets import get_preset

DateLike = Union[_dt.date, str, None]
NO_DATA = ("not_found",)


def _date(x: DateLike) -> Optional[_dt.date]:
    if x is None or x == "":
        return None
    if isinstance(x, _dt.datetime):
        return x.date()
    if isinstance(x, _dt.date):
        return x
    try:
        return _dt.date.fromisoformat(str(x)[:10])
    except ValueError:
        return None


def months_before(day: _dt.date, months: int) -> _dt.date:
    y, m = divmod(day.year * 12 + day.month - 1 - months, 12)
    m += 1
    return _dt.date(y, m, min(day.day, calendar.monthrange(y, m)[1]))


def settings_of(rules: dict, settings: Optional[dict] = None) -> dict:
    s = dict(rules.get("settings") or {})
    s.update(settings or {})
    return s


def _facts(sheet: dict):
    for b in sheet.get("blocks") or []:
        for f in b.get("facts") or []:
            yield b, f


def _live(f: dict) -> bool:
    return f.get("diff") != "gone"


def _has_data(f: dict) -> bool:
    return _live(f) and f.get("status") not in NO_DATA and f.get("origin") != "readiness"


def _block(sheet: dict, block_type: str) -> Optional[dict]:
    for b in sheet.get("blocks") or []:
        if b.get("type") == block_type:
            return b
    return None


def _short(f: dict, n: int = 60) -> str:
    t = (f.get("label") + ": " + f.get("text", "")) if f.get("label") else f.get("text", "")
    t = " ".join(t.split())
    return t if len(t) <= n else t[: n - 3].rstrip() + "..."


def stale_fact_ids(sheet: dict, today: DateLike = None, months: int = 6) -> List[str]:
    """Facts already marked stale, and facts whose sources all have a modified_at older than `months`."""
    day = _date(today) or _dt.date.today()
    cutoff = months_before(day, int(months))
    src = {s.get("id"): s for s in sheet.get("sources") or []}
    out = []
    for _, f in _facts(sheet):
        if not _live(f) or f.get("origin") == "readiness":
            continue
        if f.get("superseded_by"):
            continue                  # 0.10.0 (round 2): replaced by a newer value, not a gap
        if f.get("status") == "stale":
            out.append(f["id"])
            continue
        if f.get("status") in ("edited", "not_found") or f.get("origin") == "user":
            continue
        dates = [_date(src.get(i, {}).get("modified_at")) for i in f.get("source_ids") or []]
        if dates and all(d is not None and d < cutoff for d in dates):
            out.append(f["id"])
    return out


def mark_stale(sheet: dict, today: DateLike = None, months: int = 6) -> List[str]:
    """Sets status stale on the old facts (never on edited or user facts). Returns the ids changed."""
    ids = set(stale_fact_ids(sheet, today, months))
    changed = []
    for _, f in _facts(sheet):
        if f["id"] in ids and f.get("status") in ("found", "needs_check"):
            f["status"] = "stale"
            changed.append(f["id"])
    return changed


def _criteria(rules: dict, method: str) -> List[dict]:
    return ((rules.get("sales_methods") or {}).get(method) or {}).get("criteria") or []


def _level(block: dict, key: str) -> Tuple[str, Optional[dict]]:
    for f in block.get("facts") or []:
        if _live(f) and (f.get("value") or {}).get("key") == key:
            if f.get("status") == "not_found":
                return "unknown", f
            return (f.get("value") or {}).get("level") or "unknown", f
    return "unknown", None


def _method(rules: dict, block: dict) -> str:
    return block.get("method") or (rules.get("qualification") or {}).get("default_method", "bant")


def _asked(sheet: dict, key: str) -> bool:
    q = _block(sheet, "questions")
    return bool(q and any(_live(f) and (f.get("value") or {}).get("key") == key for f in q.get("facts") or []))


def _conflict_groups(sheet: dict) -> List[List[dict]]:
    facts = {f["id"]: f for _, f in _facts(sheet) if _live(f) and f.get("status") == "conflict"}
    seen: Set[str] = set()
    groups = []
    for fid in facts:                                # order of the sheet
        if fid in seen:
            continue
        group, todo = [], [fid]
        while todo:
            x = todo.pop()
            if x in seen or x not in facts:
                continue
            seen.add(x)
            group.append(facts[x])
            todo.extend(facts[x].get("conflict_with") or [])
            todo.extend(y for y, g in facts.items() if x in (g.get("conflict_with") or []))
        order = list(facts)
        groups.append(sorted(group, key=lambda g: order.index(g["id"])))
    return groups


def _run_rule(sheet: dict, rules: dict, rule_id: str, rule: dict, today, sett) -> Tuple[Optional[List[dict]], bool]:
    """(gaps, skipped). gaps without ids and severity yet: {text, block?, fact?, action?, suffix?}."""
    kind, params = rule.get("check"), rule.get("params") or {}
    gap = rule.get("gap", rule_id)
    if kind == "field":
        cur = sheet
        for k in str(params.get("path", "")).split("."):
            cur = cur.get(k) if isinstance(cur, dict) else None
        return ([] if isinstance(cur, str) and cur.strip() else [{"text": gap}]), False
    if kind == "participants":
        p = sheet.get("participants") or {}
        missing = [s for s in params.get("sides", ("ours", "theirs")) if not p.get(s)]
        return ([{"text": gap, "suffix": "-".join(missing)}] if missing else []), False
    block = _block(sheet, params.get("block", "")) if params.get("block") else None
    if params.get("block") and block is None:
        return [], True
    if kind == "block_facts":
        n = sum(1 for f in block.get("facts") or [] if _has_data(f))
        return ([] if n >= int(params.get("min", 1)) else [{"text": gap, "block": block["id"]}]), False
    if kind == "qualification":
        out = []
        for c in _criteria(rules, _method(rules, block)):
            level, fact = _level(block, c["key"])
            if level == "unknown":
                name = (c.get("name") or {}).get("en", c["key"])
                g = {"text": gap.format(criterion=name), "block": block["id"], "suffix": c["key"]}
                if fact:
                    g["fact"] = fact["id"]
                if _asked(sheet, c["key"]):
                    g["action"] = "find_again"        # the question is already on the list
                out.append(g)
        return out, False
    if kind == "owners":
        return [{"text": gap.format(fact=_short(f)), "block": block["id"], "fact": f["id"], "suffix": f["id"]}
                for f in block.get("facts") or [] if _has_data(f) and not str((f.get("value") or {}).get("owner") or "").strip()], False
    if kind == "conflicts":
        out = []
        for grp in _conflict_groups(sheet):
            f = grp[0]
            b = next((b for b, x in _facts(sheet) if x is f), {})
            out.append({"text": gap.format(fact=_short(f)), "block": b.get("id"), "fact": f["id"], "suffix": f["id"]})
        return out, False
    if kind == "stale":
        months = int(sett.get("stale_months", 6))
        ids = stale_fact_ids(sheet, today, months)
        where = {f["id"]: (b, f) for b, f in _facts(sheet)}
        return [{"text": gap.format(fact=_short(where[i][1]), months=months), "block": where[i][0].get("id"),
                 "fact": i, "suffix": i} for i in ids], False
    raise ValueError(f"unknown readiness check {kind!r} in rule {rule_id!r}")


def rule_ids(sheet: dict, rules: dict, app_root=None) -> List[str]:
    p = get_preset(rules, sheet.get("preset", ""), app_root)
    return list((p or {}).get("readiness") or [])


def evaluate(sheet: dict, rules: dict, today: DateLike = None, settings: Optional[dict] = None, app_root=None) -> dict:
    sett = settings_of(rules, settings)
    library = rules.get("readiness_rules") or {}
    dropped = list((sheet.get("readiness") or {}).get("dropped") or [])
    gaps, checks = [], []
    for rid in rule_ids(sheet, rules, app_root):
        rule = library.get(rid)
        if rule is None:
            checks.append({"rule": rid, "ok": True, "skipped": True})
            continue
        if rid in dropped:
            checks.append({"rule": rid, "ok": True, "dropped": True})
            continue
        found, skipped = _run_rule(sheet, rules, rid, rule, today, sett)
        kept = []
        for g in found:
            gid = f"gap-{rid}" + (f"-{g['suffix']}" if g.get("suffix") else "")
            if gid in dropped:
                continue
            out = {"id": gid, "rule": rid, "text": g["text"], "action": g.get("action") or rule.get("action", "drop_check"),
                   "severity": rule.get("severity", "warning")}
            for k in ("block", "fact"):
                if g.get(k):
                    out[k] = g[k]
            kept.append(out)
        c = {"rule": rid, "ok": not kept}
        if skipped:
            c["skipped"] = True
        checks.append(c)
        gaps.extend(kept)
    if any(g["severity"] == "blocker" for g in gaps):
        state = "not_ready"
    elif gaps:
        state = "almost"
    else:
        state = "ready"
    return {"state": state, "gaps": gaps, "checks": checks, "dropped": dropped}


def auto_questions(sheet: dict, rules: dict, today: DateLike = None, settings: Optional[dict] = None) -> Dict[str, List[str]]:
    """settings.auto_questions: a question with origin readiness when the criterion is red or unknown. Idempotent.
    Returns {"added": [...], "removed": [...]} fact ids."""
    sett = settings_of(rules, settings)
    lib = rules.get("blocks") or {}
    lang = str(sheet.get("language") or "en")[:2]
    day = _date(today) or _dt.date.today()
    added, removed = [], []
    all_ids = {f["id"] for _, f in _facts(sheet)}
    for aq in sett.get("auto_questions") or []:
        qual = _block(sheet, "qualification")
        if qual is None:
            continue
        crit = next((c for c in _criteria(rules, _method(rules, qual)) if c["key"] == aq["criterion"]), None)
        if crit is None:
            continue
        level, _ = _level(qual, crit["key"])
        want = level in (aq.get("levels") or ["red", "unknown"])
        target = _block(sheet, aq.get("block", "questions"))
        if want and aq["id"] not in all_ids:
            if target is None:
                blocks = sheet.setdefault("blocks", [])
                target = {"id": f"b-{aq.get('block', 'questions')}", "type": aq.get("block", "questions"),
                          "title": (lib.get(aq.get("block", "questions")) or {}).get("title", "Questions"),
                          "visible": True, "only_if_data": False,
                          "order": max([b.get("order", 0) for b in blocks] or [-1]) + 1, "facts": [], "edited_by_user": False}
                blocks.append(target)
            asks = (crit.get("ask") or {}).get(lang) or (crit.get("ask") or {}).get("en") or [f"What about {aq['criterion']}?"]
            target.setdefault("facts", []).append({
                "id": aq["id"], "label": aq.get("label") or (crit.get("name") or {}).get("en", crit["key"]),
                "text": asks[0], "source_ids": [], "locator": {}, "checked_at": day.isoformat(), "status": "found",
                "origin": "readiness", "value": {"key": crit["key"]}})
            added.append(aq["id"])
        elif not want and target is not None:
            keep = []
            for f in target.get("facts") or []:
                if f.get("id") == aq["id"] and f.get("origin") == "readiness" and f.get("status") != "edited":
                    removed.append(f["id"])
                else:
                    keep.append(f)
            target["facts"] = keep
    return {"added": added, "removed": removed}


def apply(sheet: dict, rules: dict, today: DateLike = None, settings: Optional[dict] = None, app_root=None) -> dict:
    sett = settings_of(rules, settings)
    auto_questions(sheet, rules, today, sett)
    mark_stale(sheet, today, int(sett.get("stale_months", 6)))
    r = evaluate(sheet, rules, today, sett, app_root)
    sheet["readiness"] = r
    return r
