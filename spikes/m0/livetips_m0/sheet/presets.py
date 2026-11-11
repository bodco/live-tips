"""0.10.0 (Meeting Sheet, phase 1): the shared presets (rules/meeting-sheet.yaml) and the user's own presets.

The user's presets are YAML files in the app folder, never in the shared rules: <appRoot>/meeting-sheet/presets/<id>.yaml
with {id, name, mode, blocks: [type, ...], readiness: [rule, ...], method?, base?}. A deleted preset is moved to
presets/_deleted/ (the app asks first), so a mistake can be undone by hand.
"""
import datetime as _dt
import re
import shutil
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import yaml

from . import SCHEMA
from ..rules import DEFAULT_RULES

USER_PREFIX = "my_"


def load_rules(rules_root: Path = DEFAULT_RULES) -> dict:
    """rules/meeting-sheet.yaml plus the qualification methods of rules/sales.yaml (key -> criteria)."""
    root = Path(rules_root)
    ms = yaml.safe_load((root / "meeting-sheet.yaml").read_text(encoding="utf-8"))
    sales_p = root / "sales.yaml"
    sales = yaml.safe_load(sales_p.read_text(encoding="utf-8")) if sales_p.exists() else {}
    ms["sales_methods"] = (sales or {}).get("methods") or {}
    return ms


def method_names(rules: dict) -> List[str]:
    """The qualification methods offered: those of meeting-sheet.yaml that rules/sales.yaml defines."""
    known = rules.get("sales_methods") or {}
    listed = (rules.get("qualification") or {}).get("methods") or list(known)
    return [m for m in listed if not known or m in known]


def presets_dir(app_root) -> Path:
    return Path(app_root).expanduser() / "meeting-sheet" / "presets"


def _shared(rules: dict) -> List[dict]:
    out = []
    for pid, p in (rules.get("presets") or {}).items():
        out.append({"id": pid, "name": p.get("name", pid), "mode": p.get("mode", "quick"),
                    "blocks": list(p.get("blocks") or []), "readiness": list(p.get("readiness") or []),
                    "source": "shared"})
    return out


def _check_preset(rules: dict, p: dict) -> List[str]:
    errs = []
    lib = rules.get("blocks") or {}
    rr = rules.get("readiness_rules") or {}
    for b in p.get("blocks") or []:
        if b not in lib:
            errs.append(f"unknown block {b!r}")
    for r in p.get("readiness") or []:
        if r not in rr:
            errs.append(f"unknown readiness rule {r!r}")
    if p.get("mode", "quick") not in ("quick", "expert"):
        errs.append(f"unknown mode {p.get('mode')!r}")
    if not str(p.get("name") or "").strip():
        errs.append("a preset needs a name")
    return errs


def user_presets(app_root, rules: dict) -> List[dict]:
    d = presets_dir(app_root) if app_root else None
    if not d or not d.is_dir():
        return []
    out = []
    for f in sorted(d.glob("*.yaml")):
        try:
            p = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue                                   # a broken file is not offered, never fatal
        if not isinstance(p, dict):
            continue
        p.setdefault("id", f.stem)
        p["source"] = "user"
        p["path"] = str(f)
        p["errors"] = _check_preset(rules, p)
        out.append(p)
    return out


def all_presets(rules: dict, app_root=None) -> List[dict]:
    return _shared(rules) + user_presets(app_root, rules)


def get_preset(rules: dict, preset_id: str, app_root=None) -> Optional[dict]:
    for p in all_presets(rules, app_root):
        if p["id"] == preset_id:
            return p
    return None


def _slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return s or "preset"


def _free_id(app_root, rules, base: str) -> str:
    taken = {p["id"] for p in all_presets(rules, app_root)}
    pid, n = base, 2
    while pid in taken:
        pid, n = f"{base}_{n}", n + 1
    return pid


def _write(app_root, p: dict) -> dict:
    d = presets_dir(app_root)
    d.mkdir(parents=True, exist_ok=True)
    keep = {k: p[k] for k in ("id", "name", "mode", "blocks", "readiness", "method", "base") if p.get(k) is not None}
    path = d / f"{keep['id']}.yaml"
    path.write_text(yaml.safe_dump(keep, sort_keys=False, allow_unicode=True), encoding="utf-8")
    return dict(keep, source="user", path=str(path))


def save_user_preset(app_root, rules: dict, name: str, blocks: Iterable[str], mode: str = "quick",
                     readiness: Optional[Iterable[str]] = None, base: Optional[str] = None,
                     method: Optional[str] = None, preset_id: Optional[str] = None) -> dict:
    """"Save as my preset": a new preset (or an overwrite of the user's preset_id). Shared ids cannot be written."""
    if readiness is None and base:
        bp = get_preset(rules, base, app_root)
        readiness = (bp or {}).get("readiness") or []
    p = {"id": preset_id or _free_id(app_root, rules, USER_PREFIX + _slug(name)), "name": name.strip(),
         "mode": mode, "blocks": list(blocks), "readiness": list(readiness or []), "base": base, "method": method}
    if p["id"] in (rules.get("presets") or {}):
        raise ValueError(f"{p['id']!r} is a shared preset")
    errs = _check_preset(rules, p)
    if errs:
        raise ValueError("; ".join(errs))
    return _write(app_root, p)


def _user(app_root, rules, preset_id) -> dict:
    for p in user_presets(app_root, rules):
        if p["id"] == preset_id:
            return p
    raise KeyError(f"no user preset {preset_id!r}")


def rename_user_preset(app_root, rules: dict, preset_id: str, name: str) -> dict:
    """The id (and the file) stay, so sheets that name the preset still find it."""
    p = _user(app_root, rules, preset_id)
    if not name.strip():
        raise ValueError("a preset needs a name")
    p["name"] = name.strip()
    return _write(app_root, p)


def duplicate_preset(app_root, rules: dict, preset_id: str, name: Optional[str] = None) -> dict:
    """A copy of any preset, shared or the user's, as a new user preset."""
    src = get_preset(rules, preset_id, app_root)
    if not src:
        raise KeyError(f"no preset {preset_id!r}")
    name = name or f"{src['name']} copy"
    return save_user_preset(app_root, rules, name, src.get("blocks") or [], src.get("mode", "quick"),
                            src.get("readiness") or [], base=src.get("base") or (preset_id if src["source"] == "shared" else None),
                            method=src.get("method"))


def delete_user_preset(app_root, rules: dict, preset_id: str) -> str:
    """Moves the file to presets/_deleted/ (the app confirms first). Returns the new path."""
    p = _user(app_root, rules, preset_id)
    trash = presets_dir(app_root) / "_deleted"
    trash.mkdir(parents=True, exist_ok=True)
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = trash / f"{preset_id}-{stamp}.yaml"
    shutil.move(p["path"], dest)
    return str(dest)


def default_mode(rules: dict, preset_id: str, earlier_sheet: bool = False, theirs: Optional[List[dict]] = None,
                 known_domains: Optional[Iterable[str]] = None, app_root=None) -> str:
    """settings.default_mode of meeting-sheet.yaml: the first matching rule, else the preset's own mode."""
    theirs = theirs or []
    known = {d.lower() for d in (known_domains or [])}
    domains = {str(x.get("domain") or "").lower() for x in theirs if x.get("domain")}
    preset = get_preset(rules, preset_id, app_root) or {}
    base = preset.get("base") or preset_id
    for r in (rules.get("settings") or {}).get("default_mode") or []:
        w = r.get("when")
        hit = ((w == "preset_in" and (preset_id in r.get("presets", []) or base in r.get("presets", [])))
               or (w == "earlier_sheet" and earlier_sheet)
               or (w == "new_external_domain" and bool(domains - known))
               or (w == "internal" and not theirs))
        if hit:
            return r["mode"]
    return preset.get("mode", "quick")


def new_sheet(rules: dict, preset_id: str, meeting: dict, participants: Optional[dict] = None,
              language: str = "en", route: str = "", project: Optional[dict] = None, mode: Optional[str] = None,
              goal: Optional[str] = None, call_type: str = "", audience: str = "", app_root=None,
              earlier_sheet: bool = False, known_domains: Optional[Iterable[str]] = None,
              sheet_id: Optional[str] = None) -> dict:
    """An empty sheet with the preset's blocks in order (no facts, no sources, not built yet)."""
    preset = get_preset(rules, preset_id, app_root)
    if not preset:
        raise KeyError(f"no preset {preset_id!r}")
    lib = rules.get("blocks") or {}
    participants = participants or {"ours": [], "theirs": []}
    participants.setdefault("ours", [])
    participants.setdefault("theirs", [])
    theirs = participants["theirs"]
    method = preset.get("method") or (rules.get("qualification") or {}).get("default_method", "bant")
    blocks = []
    for i, t in enumerate(preset.get("blocks") or []):
        b = {"id": f"b-{t}", "type": t, "title": (lib.get(t) or {}).get("title", t), "visible": True,
             "only_if_data": bool((lib.get(t) or {}).get("only_if_data", False)), "order": i, "facts": [],
             "edited_by_user": False}
        if t == "qualification":
            b["method"] = method
        blocks.append(b)
    who = theirs[0]["name"] if theirs and theirs[0].get("name") else (meeting.get("title") or "Meeting")
    start = meeting.get("start") or ""
    ref = {k: meeting[k] for k in ("event_id", "start", "end", "tz", "where") if meeting.get(k)}
    ref.setdefault("start", start)
    sheet = {
        "schema": SCHEMA,
        "id": sheet_id or f"sheet-{start[:10] or _dt.date.today().isoformat()}-{_slug(who)}",
        "title": f"Meeting Sheet: {who}",
        "meeting_ref": ref,
        "mode": mode or default_mode(rules, preset_id, earlier_sheet, theirs, known_domains, app_root),
        "preset": preset_id,
        "language": language,
        "route": route,
        "project": project or {},
        "call_type": call_type,
        "audience": audience,
        "participants": participants,
        "blocks": blocks,
        "sources": [],
        "versions": [],
    }
    if goal:
        sheet["goal"] = goal
    return sheet
