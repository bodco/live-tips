"""0.10.0 (Meeting Sheet, phase 1): the sidecar CLI. JSON out on stdout; errors as {"error": ...} with a non-zero code.

  python -m livetips_m0.sheet validate  --sheet <sheet.json>
  python -m livetips_m0.sheet readiness --sheet <sheet.json> [--today YYYY-MM-DD] [--app-root <dir>] [--no-write]
  python -m livetips_m0.sheet presets   [--request <req.json>]      list | save | rename | duplicate | delete
  python -m livetips_m0.sheet new       --request <req.json>        an empty sheet from a preset
Exit codes: 0 ok, 1 invalid sheet or failed action, 2 unknown or not yet implemented command, 3 bad input.
Not implemented in phase 1 (later phases): sources, candidates, size, build, refresh, export, derive.
"""
import argparse
import json
import sys
from pathlib import Path

from . import presets as P
from . import readiness as R
from . import schema as S

LATER = {"sources": 2, "candidates": 2, "size": 2, "build": 3, "refresh": 3, "export": 5, "derive": 3}
COMMANDS = ("validate", "readiness", "presets", "new") + tuple(LATER)


def _out(obj, code=0):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, indent=1) + "\n")
    return code


def _read_json(path):
    return json.loads(Path(path).expanduser().read_text(encoding="utf-8"))


def _write_json(path, obj):
    p = Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    tmp.replace(p)


def cmd_validate(a, req, rules):
    path = a.sheet or req.get("sheet")
    if not path:
        return _out({"error": "--sheet is required"}, 3)
    errs = S.validate(_read_json(path), P.method_names(rules))
    return _out({"ok": not errs, "errors": errs}, 0 if not errs else 1)


def cmd_readiness(a, req, rules):
    path = a.sheet or req.get("sheet")
    if not path:
        return _out({"error": "--sheet is required"}, 3)
    sheet = _read_json(path)
    errs = S.validate(sheet, P.method_names(rules))
    if errs:
        return _out({"error": "invalid sheet", "errors": errs}, 1)
    app_root = a.app_root or req.get("app_root")
    today = a.today or req.get("today")
    settings = req.get("settings") or {}
    if a.no_write or req.get("no_write"):
        r = R.evaluate(sheet, rules, today, settings, app_root)
    else:
        r = R.apply(sheet, rules, today, settings, app_root)
        _write_json(path, sheet)
    return _out(r)


def cmd_presets(a, req, rules):
    app_root = a.app_root or req.get("app_root")
    action = req.get("action", "list")
    try:
        if action == "list":
            return _out({"presets": P.all_presets(rules, app_root), "blocks": rules.get("blocks") or {},
                         "methods": P.method_names(rules), "settings": rules.get("settings") or {},
                         "readiness_rules": rules.get("readiness_rules") or {}})
        if not app_root:
            return _out({"error": "app_root is required"}, 3)
        if action == "save":
            p = P.save_user_preset(app_root, rules, req["name"], req.get("blocks") or [], req.get("mode", "quick"),
                                   req.get("readiness"), req.get("base"), req.get("method"), req.get("id"))
        elif action == "rename":
            p = P.rename_user_preset(app_root, rules, req["id"], req["name"])
        elif action == "duplicate":
            p = P.duplicate_preset(app_root, rules, req["id"], req.get("name"))
        elif action == "delete":
            return _out({"deleted": req["id"], "moved_to": P.delete_user_preset(app_root, rules, req["id"])})
        else:
            return _out({"error": f"unknown action {action!r}"}, 3)
    except (KeyError, ValueError) as e:
        return _out({"error": str(e).strip("'\"")}, 1)
    return _out({"preset": p})


def cmd_new(a, req, rules):
    if not req.get("preset") or not isinstance(req.get("meeting"), dict):
        return _out({"error": "request needs preset and meeting"}, 3)
    app_root = a.app_root or req.get("app_root")
    try:
        sheet = P.new_sheet(rules, req["preset"], req["meeting"], req.get("participants"), req.get("language", "en"),
                            req.get("route", ""), req.get("project"), req.get("mode"), req.get("goal"),
                            req.get("call_type", ""), req.get("audience", ""), app_root,
                            bool(req.get("earlier_sheet")), req.get("known_domains"), req.get("id"))
    except KeyError as e:
        return _out({"error": str(e).strip("'\"")}, 1)
    R.apply(sheet, rules, req.get("today"), req.get("settings") or {}, app_root)
    errs = S.validate(sheet, P.method_names(rules))
    if errs:
        return _out({"error": "invalid sheet", "errors": errs}, 1)
    if req.get("out"):
        _write_json(req["out"], sheet)
        return _out({"sheet": str(Path(req["out"]).expanduser()), "mode": sheet["mode"], "readiness": sheet["readiness"]})
    return _out({"sheet": sheet})


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m livetips_m0.sheet")
    ap.add_argument("command")
    ap.add_argument("--request")
    ap.add_argument("--sheet")
    ap.add_argument("--today")
    ap.add_argument("--app-root")
    ap.add_argument("--rules")
    ap.add_argument("--no-write", action="store_true")
    a, _rest = ap.parse_known_args(argv)
    if a.command not in COMMANDS:
        return _out({"error": f"unknown command {a.command!r}", "commands": list(COMMANDS)}, 2)
    if a.command in LATER:
        return _out({"error": f"{a.command} is not implemented yet (Meeting Sheet phase {LATER[a.command]})"}, 2)
    try:
        req = _read_json(a.request) if a.request else {}
    except (OSError, ValueError) as e:
        return _out({"error": f"cannot read the request: {e}"}, 3)
    rules = P.load_rules(Path(a.rules)) if a.rules else P.load_rules()
    try:
        return {"validate": cmd_validate, "readiness": cmd_readiness, "presets": cmd_presets, "new": cmd_new}[a.command](a, req, rules)
    except (OSError, ValueError) as e:
        return _out({"error": str(e)}, 3)


if __name__ == "__main__":
    sys.exit(main())
