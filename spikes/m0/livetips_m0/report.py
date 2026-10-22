"""Aggregate replay runs: latency by stage (p50, p90), cache share, cost per hour, and a
comparison with the skill's own tips for the same call.

  python -m livetips_m0.report runs/<run1> [runs/<run2> ...] [--calls-root DIR ...] [--md-out report.md]
"""
import argparse
import json
from pathlib import Path
from typing import Dict, List

from .cost import PRICES_CHECKED
from .transcript import hms_to_s


def pct(a, p):
    a = sorted(x for x in a if x is not None)
    if not a:
        return None
    k = (len(a) - 1) * p
    f = int(k)
    c = min(f + 1, len(a) - 1)
    return round(a[f] + (a[c] - a[f]) * (k - f), 2)


def jl(p: Path) -> List[dict]:
    out = []
    if p.exists():
        for raw in p.read_text(encoding="utf-8").splitlines():
            try:
                out.append(json.loads(raw))
            except ValueError:
                pass
    return out


def skill_tips(md: Path):
    """The skill's tips for the same call (kind tip/fact/answer without a typed question)."""
    stem = md.name[:-3]
    tips = jl(md.parent / (stem + ".tips.jsonl"))
    timing = {}
    for r in jl(Path(str(md) + ".timing.jsonl")):
        timing.setdefault(r.get("t"), r)
    out = []
    for t in tips:
        if t.get("kind") not in ("tip", "fact", "answer") or t.get("q") or "src" not in t or "at" not in t:
            continue
        try:
            at = hms_to_s(t["at"][:8]); src = hms_to_s(t["src"][:8])
        except Exception:
            continue
        rec = timing.get(t["src"][:8])
        seg_end = hms_to_s(rec["seg_end"]) if rec and rec.get("seg_end") else None
        out.append({"src_s": src, "e2e_s": (at - seg_end) if seg_end else None, "level": t.get("level"), "gist": t.get("gist")})
    return out


def analyse_run(run: Path, calls_root: List[Path]) -> Dict:
    meta = json.loads(next(run.glob("*.app.run.json")).read_text())
    stem = meta["md"][:-3]
    timing = jl(run / (stem + ".app.timing.jsonl"))
    llm = jl(run / (stem + ".app.llm.jsonl"))
    summ = json.loads((run / (stem + ".app.summary.json")).read_text()) if (run / (stem + ".app.summary.json")).exists() else {}
    em = [s for s in timing if s.get("outcome") == "emitted"]
    asr_lag = [s["written"] - s["seg_end"] for s in em if s.get("written") and s.get("seg_end")]
    wait = [s["available_at"] - s["written"] for s in em if s.get("written")]
    cls = [s.get("classify_ms") / 1000 for s in em if s.get("classify_ms") is not None]
    ttft = [s["tip_ttft_ms"] / 1000 for s in em if s.get("tip_ttft_ms") is not None]
    gist = [s["tip_gist_ms"] / 1000 for s in em if s.get("tip_gist_ms") is not None]
    tipms = [s["tip_ms"] / 1000 for s in em if s.get("tip_ms") is not None]
    e2e = [s.get("e2e_s") for s in em]
    e2eg = [s.get("e2e_gist_s") for s in em]
    red = [s.get("e2e_s") for s in em if s.get("level") == "red"]
    direct = [s.get("e2e_s") for s in em if s.get("route") == "direct"]
    via_cls = [s.get("e2e_s") for s in em if s.get("route") in ("classify", "periodic", "classify_pending")]
    tot_in = sum(r.get("input", 0) + r.get("cache_read", 0) + r.get("cache_write_5m", 0) + r.get("cache_write_1h", 0) for r in llm)
    cache_read = sum(r.get("cache_read", 0) for r in llm)
    usd = sum(r.get("usd") or 0 for r in llm)
    hours = (summ.get("call_span_s") or 0) / 3600 or None
    errors = [r for r in llm if r.get("error")]
    outcomes = {}
    for s in timing:
        outcomes[s.get("outcome", "?")] = outcomes.get(s.get("outcome", "?"), 0) + 1
    by_role = {}
    for r in llm:
        d = by_role.setdefault(r["role"], {"n": 0, "ttft": [], "total": []})
        d["n"] += 1
        d["ttft"].append((r.get("ttft_ms") or 0) / 1000 if r.get("ttft_ms") is not None else None)
        d["total"].append((r.get("total_ms") or 0) / 1000 if r.get("total_ms") is not None else None)
    res = {"run": run.name, "md": meta["md"], "variant": meta.get("variant"), "models": meta.get("models"),
           "cache_ttl": meta.get("cache_ttl"), "lines": summ.get("lines"), "hours": round(hours, 3) if hours else None,
           "tips": len(em), "outcomes": outcomes,
           "stage": {"asr_lag": (pct(asr_lag, .5), pct(asr_lag, .9)), "engine_wait": (pct(wait, .5), pct(wait, .9)),
                     "classify": (pct(cls, .5), pct(cls, .9)), "tip_ttft": (pct(ttft, .5), pct(ttft, .9)),
                     "tip_gist": (pct(gist, .5), pct(gist, .9)), "tip_total": (pct(tipms, .5), pct(tipms, .9))},
           "e2e": (pct(e2e, .5), pct(e2e, .9), len([x for x in e2e if x is not None])),
           "e2e_gist": (pct(e2eg, .5), pct(e2eg, .9)),
           "e2e_red": (pct(red, .5), pct(red, .9), len(red)),
           "e2e_direct": (pct(direct, .5), pct(direct, .9), len(direct)),
           "e2e_via_classify": (pct(via_cls, .5), pct(via_cls, .9), len(via_cls)),
           "llm_calls": len(llm), "llm_errors": len(errors),
           "by_role": {k: {"n": v["n"], "ttft": (pct(v["ttft"], .5), pct(v["ttft"], .9)),
                           "total": (pct(v["total"], .5), pct(v["total"], .9))} for k, v in by_role.items()},
           "cache_share": round(cache_read / tot_in, 3) if tot_in else None,
           "usd": round(usd, 4), "usd_per_hour": round(usd / hours, 3) if hours else None}
    # The app records with its own stem (<stem>.app.md); the skill's transcript is <stem>.md.
    skill_md = meta["md"][:-7] + ".md" if meta["md"].endswith(".app.md") else meta["md"]
    for root in calls_root:
        md = root / skill_md
        if md.exists():
            sk = skill_tips(md)
            se = [x["e2e_s"] for x in sk if x["e2e_s"] is not None and -5 < x["e2e_s"] < 300]
            app_src = [hms_to_s(s["src"]) for s in em]
            matched = sum(1 for x in sk if any(abs(a - x["src_s"]) <= 15 for a in app_src))
            res["skill"] = {"tips": len(sk), "e2e": (pct(se, .5), pct(se, .9)),
                            "skill_tips_covered_by_app_15s": matched}
            break
    return res


def to_markdown(results: List[Dict]) -> str:
    out = ["Ціни: platform.claude.com/docs/en/about-claude/pricing, перевірено {}.".format(PRICES_CHECKED), "",
           "| Прогін | Варіант | Год | Підказок | e2e p50 / p90, с | gist p50 / p90 | ASR-лаг p50/p90 | classify p50/p90 | tip TTFT p50/p90 | tip повністю p50/p90 | Кеш | $ / год | Скіл e2e p50/p90 | Покриття скіла |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        st = r["stage"]
        sk = r.get("skill", {})
        out.append("| {} | {} | {} | {} | {} / {} | {} / {} | {} / {} | {} / {} | {} / {} | {} / {} | {} | {} | {} | {} |".format(
            r["md"][:40], r.get("variant"), r.get("hours"), r["tips"], r["e2e"][0], r["e2e"][1], r["e2e_gist"][0], r["e2e_gist"][1],
            st["asr_lag"][0], st["asr_lag"][1], st["classify"][0], st["classify"][1], st["tip_ttft"][0], st["tip_ttft"][1],
            st["tip_total"][0], st["tip_total"][1], r.get("cache_share"), r.get("usd_per_hour"),
            "{} / {}".format(*sk["e2e"]) if sk else "-", "{}/{}".format(sk.get("skill_tips_covered_by_app_15s"), sk.get("tips")) if sk else "-"))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", type=Path)
    ap.add_argument("--calls-root", action="append", type=Path, default=[])
    ap.add_argument("--json-out", type=Path)
    ap.add_argument("--md-out", type=Path)
    a = ap.parse_args(argv)
    res = [analyse_run(r, a.calls_root) for r in a.runs if list(r.glob("*.app.run.json"))]
    if a.json_out:
        a.json_out.write_text(json.dumps(res, ensure_ascii=False, indent=1))
    md = to_markdown(res)
    if a.md_out:
        a.md_out.write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()
