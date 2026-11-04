#!/usr/bin/env python3
"""Compare model providers on the synthetic meetings in Fixtures/bench (Claude, OpenAI, Gemini; 0.9.3).

Runs the real tips engine over each meeting with each variant (livetips_m0.replay, faster than real time), then
prints one table (cost, latency, tips, errors) and writes the tips of every variant side by side for a quality read.
The meetings are invented (American names only); nothing here is a client's call.

  python3 tools/provider_bench.py --secrets ~/work/Secrets/secrets.env --out ~/work/Bodco/Pacenote/private/bench-out \\
      [--variants claude-haiku-sonnet openai-luna-sol gemini-lite-flash] [--meetings bench-incident-uk] [--speed 30] [--dry]

Keys are read from the secrets file by NAME (CLAUDE_API, OPENAI_API_KEY, GEMINI_API_KEY) and never printed.
--dry uses the fake provider: checks the plumbing without any key or network. The run needs a network that reaches
the three vendors, so it runs on the Mac, not in a sandbox. --out belongs outside the repository.
Latency numbers need --speed 1 (real time); at a higher speed they only compare the variants with each other."""
import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
M0 = REPO / "spikes" / "m0"
BENCH = REPO / "Fixtures" / "bench"

LITE, FLASH, ARGON = "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"
VARIANTS = {
    "claude-haiku": ("anthropic", {"classify": "claude-haiku-5-5", "tip": "claude-haiku-5-5"}),
    "claude-haiku-sonnet": ("anthropic", {"classify": "claude-haiku-5-5", "tip": "claude-sonnet-5-5"}),
    "openai-luna": ("openai", {"classify": "gpt-6-luna", "tip": "gpt-6-luna"}),
    "openai-luna-sol": ("openai", {"classify": "gpt-6-luna", "tip": "gpt-6.1-sol"}),
    "gemini-lite": ("gemini", {"classify": LITE, "tip": LITE}),
    "gemini-lite-flash": ("gemini", {"classify": LITE, "tip": FLASH}),
    "gemini-lite-argon": ("gemini", {"classify": LITE, "tip": ARGON}),
}


def config(variant, secrets, dry):
    kind, models = VARIANTS[variant]
    cfg = json.loads((M0 / "config.example.json").read_text())
    cfg.update({"variant": variant, "provider": kind, "models": models, "secrets_file": secrets,
                "me_label": "Me", "them_label": "Other", "name_aliases": ["Mike"], "langs": ["en", "uk"],
                "tips_lang": "en", "call_type": "auto", "answer_any": True,
                "budget": {"ledger": "~/.livetips/bench-spend.json", "call_soft_usd": 1.0, "call_hard_usd": 3.0,
                           "monthly_hard_usd": 50.0}})
    if kind != "anthropic":
        cfg.pop("request_extra", None)          # the thinking settings are Claude's; the other providers set their own
        cfg.pop("workspace_id_env", None)
    if dry:
        cfg["provider"] = "fake"
    return cfg


def rows(path):
    if not path.exists():
        return []
    return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines() if x.strip()]


def summarize(out, stem):
    llm = rows(out / (stem + ".app.llm.jsonl"))
    tips = [t for t in rows(out / (stem + ".app.tips.jsonl")) if t.get("kind") != "retract" and not t.get("partial")]
    tot = [r["total_ms"] for r in llm if r.get("total_ms")]
    return {"requests": len(llm), "errors": sum(1 for r in llm if r.get("error")), "tips": len(tips),
            "usd": round(sum(r.get("usd") or 0 for r in llm), 4),
            "p50_ms": int(statistics.median(tot)) if tot else None,
            "p95_ms": int(sorted(tot)[int(len(tot) * 0.95) - 1]) if len(tot) >= 2 else (tot[0] if tot else None),
            "tip_texts": [(t.get("t"), t.get("gist") or t.get("text") or "") for t in tips]}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--secrets", default="~/work/Secrets/secrets.env")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--variants", nargs="*", default=list(VARIANTS))
    ap.add_argument("--meetings", nargs="*", help="stems in Fixtures/bench; default all")
    ap.add_argument("--speed", type=float, default=30.0)
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args(argv)
    meetings = sorted(p for p in BENCH.glob("*.md") if not a.meetings or p.stem in a.meetings)
    if not meetings:
        sys.exit("no meetings in " + str(BENCH))
    result = {}
    for v in a.variants:
        for md in meetings:
            out = a.out.expanduser() / v / md.stem
            out.mkdir(parents=True, exist_ok=True)
            cfg_path = out / "config.json"
            cfg_path.write_text(json.dumps(config(v, a.secrets, a.dry), indent=1))
            t0 = time.monotonic()
            p = subprocess.run([sys.executable, "-m", "livetips_m0.replay", "--config", str(cfg_path), "--md", str(md),
                                "--out", str(out), "--speed", str(a.speed)], cwd=M0, capture_output=True, text=True)
            row = summarize(out, md.name[:-3])
            row["exit"], row["wall_s"] = p.returncode, int(time.monotonic() - t0)
            if p.returncode:
                row["stderr"] = p.stderr.strip()[-300:]          # never the prompt; engine errors name the status only
            result[(v, md.stem)] = row
            print("%-22s %-24s exit %d  tips %2d  err %d  $%.4f  p50 %s ms" % (
                v, md.stem, row["exit"], row["tips"], row["errors"], row["usd"], row["p50_ms"]), flush=True)
    report = ["# Provider bench (synthetic meetings)", "", "| variant | meeting | tips | errors | $ | p50 ms | p95 ms |", "|---|---|---|---|---|---|---|"]
    for (v, m), r in result.items():
        report.append("| %s | %s | %d | %d | %.4f | %s | %s |" % (v, m, r["tips"], r["errors"], r["usd"], r["p50_ms"], r["p95_ms"]))
    report += ["", "## Tips side by side", ""]
    for md in meetings:
        report += ["### " + md.stem, ""]
        for v in a.variants:
            r = result.get((v, md.stem), {})
            report.append("**%s**" % v)
            report += ["- %s %s" % (t or "", g) for t, g in r.get("tip_texts", [])] or ["- (no tips)"]
            report.append("")
    (a.out.expanduser() / "bench-report.md").write_text("\n".join(report), encoding="utf-8")
    print("report:", a.out.expanduser() / "bench-report.md")
    return 0 if all(r["exit"] == 0 for r in result.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
