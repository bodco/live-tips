"""0.10.0 (Meeting Sheet, phase 1): the validator of sheet.json v1 (schema pacenote.sheet/1).

validate(sheet) returns a list of errors ("<path>: <what>"), empty when the sheet is valid. Unknown keys are allowed
(a newer app may add fields); unknown enum values are errors here, the Swift models only tolerate them on reading.
"""
from typing import Any, Dict, Iterable, List, Optional

from . import SCHEMA

MODES = ("quick", "expert")
BLOCK_TYPES = ("header", "my_focus", "company", "signals", "tech_stack", "fit", "contact", "qualification", "history",
               "project_context", "agenda", "action_items", "questions", "best_outcome", "red_lines", "structure_roles",
               "overview", "gaps", "standup_since", "standup_today", "standup_blockers", "standup_waiting",
               "interview_candidate", "interview_role")
FACT_STATUS = ("found", "not_found", "needs_check", "conflict", "stale", "edited")
ORIGINS = ("model", "user", "readiness")
LEVELS = ("green", "yellow", "red", "unknown")
DIFFS = ("new", "changed", "gone")
SOURCE_TYPES = ("file", "folder_file", "gdoc", "gsheet", "gslides", "drive_file", "notion", "web", "web_page",
                "linkedin", "linkedin_manual", "text", "prev_call", "tracker", "web_search", "crm", "project_state",
                "digest", "transcript", "folder")      # 0.10.0 (Meeting Sheet, folders): folder
ACCESS = ("ok", "denied", "unsupported", "pending")
FIX_ACTIONS = ("confirm_google", "connect_notion", "connect_google", "open_in_browser", "save_as_pdf", "paste_text",
               "fill_by_hand", "retry")
USED = ("full", "summarized", "truncated", "skipped", "not_used")
SIZE_STATES = ("fits", "near", "too_much")
PLAN_MODES = ("one", "passes", "compress")
READINESS = ("ready", "almost", "not_ready")
GAP_ACTIONS = ("add_question", "find_again", "mark_checked", "drop_check", "assign_owner", "add_source")
SEVERITIES = ("blocker", "warning")
# A fact of these statuses, written by the model, must name at least one source.
SOURCED = ("found", "conflict", "stale")


class _V:
    def __init__(self):
        self.errors: List[str] = []

    def err(self, path, what):
        self.errors.append(f"{path}: {what}")

    def obj(self, v, path) -> bool:
        if not isinstance(v, dict):
            self.err(path, "must be an object")
            return False
        return True

    def req(self, o, keys: Iterable[str], path):
        for k in keys:
            if k not in o or o[k] is None:
                self.err(f"{path}.{k}", "required")

    def typ(self, o, key, types, path, optional=True):
        if key not in o or o[key] is None:
            if not optional:
                self.err(f"{path}.{key}", "required")
            return
        v = o[key]
        if isinstance(v, bool) and bool not in (types if isinstance(types, tuple) else (types,)):
            self.err(f"{path}.{key}", f"must be {_tname(types)}")
        elif not isinstance(v, types):
            self.err(f"{path}.{key}", f"must be {_tname(types)}")

    def enum(self, o, key, values, path, optional=True):
        if key not in o or o[key] is None:
            if not optional:
                self.err(f"{path}.{key}", "required")
            return
        if o[key] not in values:
            self.err(f"{path}.{key}", f"unknown value {o[key]!r}")

    def strs(self, o, key, path):
        v = o.get(key)
        if v is None:
            return
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            self.err(f"{path}.{key}", "must be a list of strings")


def _tname(t):
    names = {str: "a string", int: "a number", float: "a number", bool: "true or false", list: "a list", dict: "an object"}
    ts = t if isinstance(t, tuple) else (t,)
    return " or ".join(dict.fromkeys(names.get(x, x.__name__) for x in ts))


def validate(sheet: Any, methods: Optional[Iterable[str]] = None) -> List[str]:
    """Errors of a sheet; methods = the allowed qualification methods (None = any string)."""
    v = _V()
    if not v.obj(sheet, "sheet"):
        return v.errors
    p = "sheet"
    v.req(sheet, ("schema", "id", "title", "meeting_ref", "mode", "preset", "language", "blocks", "sources"), p)
    if sheet.get("schema") not in (None, SCHEMA):
        v.err(f"{p}.schema", f"must be {SCHEMA!r}")
    for k in ("id", "title", "preset", "language", "route", "call_type", "audience", "goal", "built_at", "refreshed_at"):
        v.typ(sheet, k, str, p)
    v.enum(sheet, "mode", MODES, p)
    mr = sheet.get("meeting_ref")
    if mr is not None and v.obj(mr, f"{p}.meeting_ref"):
        v.req(mr, ("start",), f"{p}.meeting_ref")
        for k in ("event_id", "start", "end", "tz", "where"):
            v.typ(mr, k, str, f"{p}.meeting_ref")
    pr = sheet.get("project")
    if pr is not None and v.obj(pr, f"{p}.project"):
        for k in ("slug", "root"):
            v.typ(pr, k, str, f"{p}.project")
    _participants(v, sheet.get("participants"), f"{p}.participants")

    sources = sheet.get("sources") or []
    source_ids = set()
    if not isinstance(sources, list):
        v.err(f"{p}.sources", "must be a list")
        sources = []
    ns = set()
    for i, s in enumerate(sources):
        sp = f"{p}.sources[{i}]"
        if not v.obj(s, sp):
            continue
        _source(v, s, sp)
        sid = s.get("id")
        if isinstance(sid, str):
            if sid in source_ids:
                v.err(f"{sp}.id", f"duplicate id {sid!r}")
            source_ids.add(sid)
        n = s.get("n")
        if isinstance(n, int) and not isinstance(n, bool):
            if n in ns:
                v.err(f"{sp}.n", f"duplicate number {n}")
            ns.add(n)

    blocks = sheet.get("blocks") or []
    if not isinstance(blocks, list):
        v.err(f"{p}.blocks", "must be a list")
        blocks = []
    block_ids, fact_ids, conflicts = set(), set(), []
    for i, b in enumerate(blocks):
        bp = f"{p}.blocks[{i}]"
        if not v.obj(b, bp):
            continue
        v.req(b, ("id", "type", "title", "visible", "only_if_data", "order", "facts", "edited_by_user"), bp)
        for k in ("id", "title"):
            v.typ(b, k, str, bp)
        v.enum(b, "type", BLOCK_TYPES, bp)
        for k in ("visible", "only_if_data", "edited_by_user"):
            v.typ(b, k, bool, bp)
        v.typ(b, "order", int, bp)
        if b.get("method") is not None:
            v.typ(b, "method", str, bp)
            if methods is not None and isinstance(b.get("method"), str) and b["method"] not in set(methods):
                v.err(f"{bp}.method", f"unknown method {b['method']!r}")
        bid = b.get("id")
        if isinstance(bid, str):
            if bid in block_ids:
                v.err(f"{bp}.id", f"duplicate id {bid!r}")
            block_ids.add(bid)
        facts = b.get("facts")
        if facts is None:
            continue
        if not isinstance(facts, list):
            v.err(f"{bp}.facts", "must be a list")
            continue
        for j, f in enumerate(facts):
            fp = f"{bp}.facts[{j}]"
            if not v.obj(f, fp):
                continue
            _fact(v, f, fp, source_ids)
            fid = f.get("id")
            if isinstance(fid, str):
                if fid in fact_ids:
                    v.err(f"{fp}.id", f"duplicate id {fid!r}")
                fact_ids.add(fid)
            if isinstance(f.get("conflict_with"), list):
                conflicts.append((fp, f["conflict_with"]))
    for fp, ids in conflicts:
        for x in ids:
            if x not in fact_ids:
                v.err(f"{fp}.conflict_with", f"unknown fact {x!r}")

    if sheet.get("size_report") is not None:
        _size(v, sheet["size_report"], f"{p}.size_report", source_ids)
    if sheet.get("readiness") is not None:
        _readiness(v, sheet["readiness"], f"{p}.readiness")
    vs = sheet.get("versions")
    if vs is not None:
        if not isinstance(vs, list):
            v.err(f"{p}.versions", "must be a list")
        else:
            for i, x in enumerate(vs):
                xp = f"{p}.versions[{i}]"
                if v.obj(x, xp):
                    v.req(x, ("n", "built_at"), xp)
                    v.typ(x, "n", int, xp)
                    for k in ("built_at", "route", "model", "note"):
                        v.typ(x, k, str, xp)
    d = sheet.get("diff")
    if d is not None and v.obj(d, f"{p}.diff"):
        for k in ("new", "changed", "gone"):
            v.strs(d, k, f"{p}.diff")
    return v.errors


def _participants(v, o, p):
    if o is None or not v.obj(o, p):
        return
    for side in ("ours", "theirs"):
        lst = o.get(side)
        if lst is None:
            continue
        if not isinstance(lst, list):
            v.err(f"{p}.{side}", "must be a list")
            continue
        for i, x in enumerate(lst):
            xp = f"{p}.{side}[{i}]"
            if v.obj(x, xp):
                v.req(x, ("name",), xp)
                for k in ("name", "role", "company", "domain"):
                    v.typ(x, k, str, xp)


def _source(v, s, p):
    v.req(s, ("id", "n", "type", "title", "access", "used"), p)
    v.typ(s, "id", str, p)
    v.typ(s, "n", int, p)
    v.enum(s, "type", SOURCE_TYPES, p)
    for k in ("uri", "path", "title", "access_reason", "reason", "modified_at", "parent"):
        v.typ(s, k, str, p)
    for k in ("size_tokens", "chars", "pass", "days"):
        v.typ(s, k, int, p)
    fo = s.get("folder")             # 0.10.0 (Meeting Sheet, folders): the folder's counts
    if fo is not None and v.obj(fo, f"{p}.folder"):
        for k in ("days", "recent", "in_window", "searchable", "over_budget", "tokens"):
            v.typ(fo, k, int, f"{p}.folder")
        v.typ(fo, "fallback", bool, f"{p}.folder")
    v.enum(s, "access", ACCESS, p)
    v.enum(s, "fix_action", FIX_ACTIONS, p)
    v.enum(s, "used", USED, p)
    v.typ(s, "auto", bool, p)
    v.strs(s, "why", p)
    dk = s.get("deck")
    if dk is not None and v.obj(dk, f"{p}.deck"):
        v.typ(dk, "owners", dict, f"{p}.deck")
        for k in ("minutes", "qa_minutes"):
            v.typ(dk, k, (int, float), f"{p}.deck")


def _fact(v, f, p, source_ids):
    v.req(f, ("id", "text", "source_ids", "status", "origin"), p)
    for k in ("id", "label", "text", "checked_at"):
        v.typ(f, k, str, p)
    v.enum(f, "status", FACT_STATUS, p)
    v.enum(f, "origin", ORIGINS, p)
    v.enum(f, "diff", DIFFS, p)
    v.strs(f, "source_ids", p)
    sids = f.get("source_ids") if isinstance(f.get("source_ids"), list) else []
    for x in sids:
        if x not in source_ids:
            v.err(f"{p}.source_ids", f"unknown source {x!r}")
    if f.get("origin") == "model" and f.get("status") in SOURCED:
        if not sids:
            v.err(f"{p}.source_ids", "a model fact needs at least one source")
        if not f.get("checked_at"):
            v.err(f"{p}.checked_at", "required for a sourced fact")
    loc = f.get("locator")
    if loc is not None and v.obj(loc, f"{p}.locator"):
        for k in ("quote", "url", "cell"):
            v.typ(loc, k, str, f"{p}.locator")
        for k in ("line", "page", "slide"):
            v.typ(loc, k, int, f"{p}.locator")
    cw = f.get("conflict_with")
    v.strs(f, "conflict_with", p)
    if f.get("status") == "conflict" and not cw:
        v.err(f"{p}.conflict_with", "a conflict names the other fact")
    val = f.get("value")
    if val is not None and v.obj(val, f"{p}.value"):
        v.enum(val, "level", LEVELS, f"{p}.value")
        for k in ("key", "owner", "due"):
            v.typ(val, k, str, f"{p}.value")


def _size(v, s, p, source_ids):
    if not v.obj(s, p):
        return
    for k in ("route", "model"):
        v.typ(s, k, str, p)
    for k in ("window", "reserve", "total_tokens"):
        v.typ(s, k, int, p)
    v.enum(s, "state", SIZE_STATES, p)
    plan = s.get("plan")
    if plan is not None and v.obj(plan, f"{p}.plan"):
        v.enum(plan, "mode", PLAN_MODES, f"{p}.plan", optional=False)
        for i, ps in enumerate(plan.get("passes") or []):
            pp = f"{p}.plan.passes[{i}]"
            if v.obj(ps, pp):
                v.typ(ps, "n", int, pp)
                v.strs(ps, "source_ids", pp)
                for x in ps.get("source_ids") or []:
                    if x not in source_ids:
                        v.err(f"{pp}.source_ids", f"unknown source {x!r}")


def _readiness(v, r, p):
    if not v.obj(r, p):
        return
    v.enum(r, "state", READINESS, p, optional=False)
    v.strs(r, "dropped", p)
    gaps = r.get("gaps") or []
    if not isinstance(gaps, list):
        v.err(f"{p}.gaps", "must be a list")
        gaps = []
    ids = set()
    for i, g in enumerate(gaps):
        gp = f"{p}.gaps[{i}]"
        if not v.obj(g, gp):
            continue
        v.req(g, ("id", "rule", "text", "action", "severity"), gp)
        for k in ("id", "rule", "text", "block", "fact"):
            v.typ(g, k, str, gp)
        v.enum(g, "action", GAP_ACTIONS, gp)
        v.enum(g, "severity", SEVERITIES, gp)
        if g.get("id") in ids:
            v.err(f"{gp}.id", f"duplicate id {g.get('id')!r}")
        ids.add(g.get("id"))
    for i, c in enumerate(r.get("checks") or []):
        cp = f"{p}.checks[{i}]"
        if v.obj(c, cp):
            v.req(c, ("rule", "ok"), cp)
            v.typ(c, "rule", str, cp)
            v.typ(c, "ok", bool, cp)
            v.typ(c, "dropped", bool, cp)
            v.typ(c, "skipped", bool, cp)
