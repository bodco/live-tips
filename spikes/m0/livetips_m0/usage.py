"""Pacenote 0.8.7 (M, rules/usage.yaml): the engine's side of the local feature usage log, same format as the app's
UsageLog: <app_root>/usage/YYYY-MM.jsonl, one line {"t", "e", "p"}. Only event names and small parameters, never
call text. Off when LT_USAGE_DIR is not set (the app sets it when Settings > General > Privacy allows the log)."""
from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path

EVENTS = {"tip_shown": ["kind"], "tip_action": ["kind", "action"], "help_now": [], "ask_typed": [], "hotkey": ["name"],
          "slide_sync": ["variant"], "prepare_run": ["type", "source", "seconds"], "rehearsal_finished": ["score"]}


def line(event: str, params: dict | None = None, now: dt.datetime | None = None, events: dict = EVENTS) -> dict | None:
    if event not in events:
        return None
    p = {}
    for k, v in (params or {}).items():
        if k not in events[event] or not isinstance(v, (str, int, float, bool)):
            return None
        if isinstance(v, str) and len(v) > 80:
            return None
        p[k] = v
    t = (now or dt.datetime.now(dt.timezone.utc)).isoformat(timespec="seconds")
    return {"t": t, "e": event, "p": p}


def log(event: str, params: dict | None = None) -> None:
    d = os.environ.get("LT_USAGE_DIR", "")
    rec = line(event, params) if d else None
    if not rec:
        return
    try:
        Path(d).mkdir(parents=True, exist_ok=True)
        with open(Path(d) / (dt.date.today().strftime("%Y-%m") + ".jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
    except OSError:
        pass
