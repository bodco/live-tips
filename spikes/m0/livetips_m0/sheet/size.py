"""0.10.0 (Meeting Sheet, phase 2): the size of the sources in tokens for the chosen route (S4 "Will it fit?").

Tokens, not characters: a calibrated estimate per script (rules/ai.yaml > windows.routes.<route>.chars_per_token;
Cyrillic takes more tokens per character than Latin), the provider's window and the answer reserve from the same file.
The state is fits | near | too_much; nothing is cut here. When the sources do not fit one pass, the report proposes
a plan (several passes and a merge, or summaries of the biggest sources first); the user chooses, never automatic.
"""
import math
import re
from pathlib import Path
from typing import Dict, List, Optional

import yaml

from ..rules import DEFAULT_RULES

CYR = re.compile(r"[Ѐ-ӿ]")
LAT = re.compile(r"[A-Za-z]")
DIG = re.compile(r"\d")
SPACE = re.compile(r"\s")
FALLBACK = {"window": 128000, "reserve": 12000, "chars_per_token": {"latin": 4.0, "cyrillic": 2.6}}
PROMPT_TOKENS = 2500       # the sheet contract, the blocks and the meeting header
MERGE_TOKENS = 40000       # the merge pass of a multi-pass build (the facts of every pass)


def load_windows(rules_root: Path = DEFAULT_RULES) -> dict:
    try:
        ai = yaml.safe_load((Path(rules_root) / "ai.yaml").read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        ai = {}
    return ai.get("windows") or {}


def route_key(route: str) -> str:
    r = (route or "").lower()
    return {"plan": "code", "claude_account": "code", "claude": "code", "claude_api": "api", "chatgpt": "codex",
            "chatgpt_account": "codex", "ollama": "local", "gemini_account": "agy"}.get(r, r)


def route_info(route: str, windows: dict, model: Optional[str] = None) -> dict:
    r = route_key(route)
    base = dict(FALLBACK)
    base.update((windows.get("routes") or {}).get(r) or {})
    if model and model in (windows.get("models") or {}):
        m = windows["models"][model]
        base.update({k: v for k, v in m.items() if k in ("window", "input", "unverified")})
        base["model"] = model
    elif model:
        base["model"] = model
    base.setdefault("reserve", windows.get("default_reserve", 12000))
    base["route"] = r
    return base


def estimate(text: str, route: str = "codex", windows: Optional[dict] = None, info: Optional[dict] = None) -> int:
    """Tokens of a text on a route: Cyrillic letters, Latin letters and the rest (digits, spaces, punctuation)
    each by their own coefficient. Spaces count a quarter (a tokenizer joins most of them to the next word)."""
    if not text:
        return 0
    info = info or route_info(route, windows if windows is not None else load_windows())
    cpt = info.get("chars_per_token") or FALLBACK["chars_per_token"]
    lat, cyr = float(cpt.get("latin", 4.0)), float(cpt.get("cyrillic", 2.6))
    n_cyr = len(CYR.findall(text))
    n_lat = len(LAT.findall(text))
    n_sp = len(SPACE.findall(text))
    n_dig = len(DIG.findall(text))
    rest = max(0, len(text) - n_cyr - n_lat - n_sp - n_dig)
    t = n_cyr / cyr + n_lat / lat + n_sp / (lat * 4) + n_dig / 2.0 + rest / 1.5
    return int(math.ceil(t))


def usable(info: dict, windows: dict) -> int:
    win = int(info.get("input") or info.get("window") or FALLBACK["window"])
    win = min(win, int(info.get("window") or win))
    return max(1000, win - int(info.get("reserve") or 0) - PROMPT_TOKENS)


def per_pass(info: dict, windows: dict) -> int:
    u = usable(info, windows)
    cap = int(windows.get("pass_cap") or 0)
    return min(u, cap) if cap else u


def report(sources: List[dict], route: str, model: Optional[str] = None, windows: Optional[dict] = None,
           chosen: Optional[str] = None) -> dict:
    """size_report of the schema: route, model, window, reserve, total_tokens, state, biggest, groups and, when the
    sources do not fit one pass, the plans to choose from (passes / compress). `chosen` is the user's plan."""
    windows = windows if windows is not None else load_windows()
    info = route_info(route, windows, model)
    taken = [s for s in sources if s.get("access") == "ok" and s.get("used") != "skipped" and s.get("size_tokens")]
    total = sum(int(s.get("size_tokens") or 0) for s in taken)
    one = per_pass(info, windows)
    near = float(windows.get("near_share") or 0.8)
    state = "fits" if total <= one * near else "near" if total <= one else "too_much"
    groups = {"added": 0, "project": 0, "web": 0}
    for s in taken:
        t = s.get("type", "")
        g = "web" if t in ("web", "web_page", "linkedin", "linkedin_manual", "web_search") else \
            "project" if s.get("auto") or t in ("folder_file", "prev_call", "tracker", "project_state", "digest") else "added"
        groups[g] += int(s.get("size_tokens") or 0)
    biggest = sorted(taken, key=lambda s: -int(s.get("size_tokens") or 0))[:5]
    out = {"route": info["route"], "model": info.get("model", ""), "window": int(info.get("window") or 0),
           "reserve": int(info.get("reserve") or 0), "per_pass": one, "total_tokens": total, "state": state,
           "times": round(total / one, 2) if one else 0, "groups": groups,
           "biggest": [{"id": s["id"], "title": s.get("title", ""), "tokens": int(s.get("size_tokens") or 0)} for s in biggest]}
    if info.get("unverified"):
        out["unverified"] = True
    plans = []
    if state == "too_much":
        plans.append({"mode": "passes", "passes": plan_passes(taken, one)})
        plans.append({"mode": "compress", "summarize": compress_plan(taken, one)})
    out["plans"] = plans
    mode = chosen or "one"
    if mode == "passes":
        out["plan"] = {"mode": "passes", "passes": plan_passes(taken, one)}
    elif mode == "compress":
        out["plan"] = {"mode": "compress", "summarize": compress_plan(taken, one)}
    else:
        out["plan"] = {"mode": "one"}
    return out


def _prio(s: dict) -> tuple:
    """Pinned first (added by the user, the deck, text), then project state and earlier calls, then the folder."""
    t = s.get("type", "")
    rank = 0 if not s.get("auto") else 1 if t in ("project_state", "prev_call", "tracker", "digest", "crm") else 2
    return (rank, int(s.get("n") or 0))


def plan_passes(sources: List[dict], per: int) -> List[dict]:
    """Greedy packing in priority order; a source bigger than one pass gets a pass of its own (it is read in parts
    by the build, never cut silently)."""
    passes: List[dict] = []
    cur: List[str] = []
    size = 0
    for s in sorted(sources, key=_prio):
        t = int(s.get("size_tokens") or 0)
        if cur and size + t > per:
            passes.append({"n": len(passes) + 1, "source_ids": cur, "tokens": size})
            cur, size = [], 0
        cur.append(s["id"])
        size += t
    if cur:
        passes.append({"n": len(passes) + 1, "source_ids": cur, "tokens": size})
    return passes


def compress_plan(sources: List[dict], per: int) -> List[str]:
    """The biggest sources (the folder's first) are summarized until the rest fits one pass."""
    total = sum(int(s.get("size_tokens") or 0) for s in sources)
    out = []
    for s in sorted(sources, key=lambda s: (-(_prio(s)[0]), -int(s.get("size_tokens") or 0))):
        if total <= per * 0.9:
            break
        t = int(s.get("size_tokens") or 0)
        out.append(s["id"])
        total -= t - min(t, 1500)
    return out
