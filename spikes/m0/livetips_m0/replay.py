"""Replay a recorded call (transcript + timing) through the engine in real time.

Each line becomes available at the moment the recorder wrote it (`written` from
<stem>.md.timing.jsonl), so the ASR lag of the real call is part of the measurement.
The engine clock runs on the call's own timeline.

  python -m livetips_m0.replay --config my.json --md /path/<stem>.md --out runs/<run> [--minutes 30]
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

from .cost import BudgetGuard
from .engine import Engine
from .prompt import PromptBuilder
from .providers import make_provider, FakeProvider
from .rules import Rules
from .secret_store import load_secret
from .transcript import load_call


def call_meta_from_md(md: Path, cfg: dict) -> dict:
    head = md.read_text(encoding="utf-8", errors="replace")[:1500]
    title = re.search(r"^# Live transcript:\s*(.+)$", head, re.M)
    proj = re.search(r"^- \S+:\s*([a-z0-9-]+)\s*$", head, re.M)
    meta = {"title": title.group(1).strip() if title else md.stem, "project": proj.group(1) if proj else "",
            "audience": cfg.get("audience", "auto"), "call_type": cfg.get("call_type", "auto"),
            "langs": cfg.get("langs", ["uk", "en"]), "me_label": cfg["me_label"], "them_label": cfg["them_label"],
            "name_aliases": cfg.get("name_aliases", []), "tips_lang": cfg.get("tips_lang", "uk"),
            "hiring_role": cfg.get("hiring_role", "") if cfg.get("call_type") == "interview" else ""}
    return meta


def build_engine(cfg, md: Path, out: Path, clock, provider=None):
    rules = Rules(Path(cfg["rules_dir"])) if cfg.get("rules_dir") else Rules()
    stem = md.name[:-3]
    base = md.parent / stem
    extra = ""
    if cfg.get("call_context") or cfg.get("project_root"):
        from .context import build as build_context
        extra = build_context(cfg.get("call_context", ""), cfg.get("project_root"), cfg.get("lt_cmd"))
        if extra:
            (out / (stem + ".app.context.md")).parent.mkdir(parents=True, exist_ok=True)
            (out / (stem + ".app.context.md")).write_text(extra, encoding="utf-8")
    prompt = PromptBuilder(rules, call_meta_from_md(md, cfg), brief_path=Path(str(base) + ".brief.md"),
                           facts_path=Path(str(base) + ".facts.json"), cards_path=Path(str(base) + ".cards.json"),
                           extra_context=extra)
    if provider is None:
        provider = make_provider(cfg, lambda name: load_secret(name, cfg.get("secrets_file")))
    b = cfg.get("budget", {})
    budget = BudgetGuard(b.get("ledger", "~/.livetips/spend.json"), b.get("call_soft_usd", 2.0),
                         b.get("call_hard_usd", 5.0), b.get("monthly_hard_usd", 100.0))
    cfg.setdefault("speakers_file", str(base) + ".speakers.json")
    return Engine(cfg=cfg, rules=rules, provider=provider, prompt=prompt, out_dir=out, stem=stem,
                  clock=clock, budget=budget), stem


def replay(cfg: dict, md: Path, out: Path, minutes=None, start_min=0.0, speed=1.0, provider=None, verbose=True):
    lines = load_call(md, cfg["me_label"])
    for ln in lines:                       # older calls without timing: estimate availability
        if ln.written is None:
            ln.seg_end = ln.t_s + (ln.dur or 3.0)
            ln.written = ln.seg_end + 1.0
    lines.sort(key=lambda x: x.written)
    if not lines:
        raise SystemExit("no transcript lines in " + str(md))
    t0 = lines[0].written + start_min * 60
    t_end = t0 + minutes * 60 if minutes else float("inf")
    sel = [ln for ln in lines if t0 <= ln.written <= t_end]
    mono0 = time.monotonic()

    def clock():
        return t0 + (time.monotonic() - mono0) * speed

    eng, stem = build_engine(cfg, md, out, clock, provider)
    out.mkdir(parents=True, exist_ok=True)
    (out / (stem + ".app.run.json")).write_text(json.dumps({
        "md": md.name, "variant": cfg.get("variant"), "models": cfg["models"], "cache_ttl": cfg.get("cache_ttl"),
        "direct_route": cfg.get("direct_route", True), "speed": speed, "start_min": start_min,
        "minutes": minutes, "lines": len(sel), "started": time.strftime("%Y-%m-%d %H:%M:%S")}, ensure_ascii=False, indent=1))
    for ln in sel:
        wait = (ln.written - t0) / speed - (time.monotonic() - mono0)
        if wait > 0:
            time.sleep(wait)
        eng.on_line(ln)
    eng.drain(90)
    span_s = (sel[-1].written - sel[0].written) if len(sel) > 1 else 0
    summary = {"lines": len(sel), "call_span_s": round(span_s, 1), "tips": len(eng.tips),
               "spent_usd": round(eng.budget.call_spent, 4) if eng.budget else None}
    (out / (stem + ".app.summary.json")).write_text(json.dumps(summary, indent=1))
    if verbose:
        print(json.dumps(summary))
    return eng


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--minutes", type=float)
    ap.add_argument("--start-min", type=float, default=0.0)
    ap.add_argument("--speed", type=float, default=1.0, help="1 = real time (required for latency numbers)")
    ap.add_argument("--set", action="append", default=[], help="override config: key=json, e.g. cache_ttl=\"5m\"")
    a = ap.parse_args(argv)
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    for kv in a.set:
        k, v = kv.split("=", 1)
        cur = cfg
        parts = k.split(".")
        for p in parts[:-1]:
            cur = cur.setdefault(p, {})
        cur[parts[-1]] = json.loads(v)
    replay(cfg, a.md, a.out, a.minutes, a.start_min, a.speed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
