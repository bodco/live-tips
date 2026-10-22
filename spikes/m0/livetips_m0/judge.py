"""Blind quality judge: scores every tip of the skill and of the app on the same call.

Each tip is judged alone, with the transcript from 90 s before its trigger line to 20 s after it
was shown, without saying which engine wrote it. Order is shuffled. Output: one JSON line per tip
in <out>/judge.jsonl and a summary.

  python -m livetips_m0.judge --config cfg.json --md <call>.md --run runs/<run> --out runs/judge-<name>
"""
import argparse
import json
import random
from pathlib import Path

from .engine import first_json
from .providers import make_provider
from .report import jl, pct
from .secret_store import load_secret
from .transcript import load_call, hms_to_s

SYSTEM = """You evaluate live hints shown to a project manager (PM) in a small window during a video call.
Score ONE hint from 1 to 5:
5 = exactly what the PM needed at that moment: concrete (fact, number, owner, date or a ready sentence), correct per the transcript, shown before the PM had to answer.
4 = useful and timely, minor issues.
3 = somewhat useful, or useful but late (the PM already answered or the topic moved on).
2 = generic, mostly redundant, or about a different topic than the live one.
1 = wrong, misleading, or noise.
Judge only from the transcript; you cannot see the documents the hint may cite, so do not penalise a cited fact you cannot verify unless the transcript contradicts it.
Return JSON only: {"score": 1-5, "timely": true|false, "concrete": true|false, "reason": "<max 15 words>"}"""


def window(lines, src_s, shown_s):
    out = []
    for ln in lines:
        if src_s - 90 <= ln.t_s <= shown_s + 20:
            mark = "  <-- trigger line" if ln.t == "{:02d}:{:02d}:{:02d}".format(int(src_s) // 3600, int(src_s) % 3600 // 60, int(src_s) % 60) else ""
            out.append("[{}] {}: {}{}".format(ln.t, "PM" if ln.speaker == "me" else (ln.stag or "Other"), ln.text, mark))
    return "\n".join(out)


def tips_of(path: Path, engine: str):
    res = []
    for t in jl(path):
        if t.get("kind") not in ("tip", "fact", "answer") or t.get("q") or t.get("partial") or "src" not in t or "at" not in t:
            continue
        try:
            res.append({"engine": engine, "src_s": hms_to_s(t["src"][:8]), "at_s": hms_to_s(t["at"][:8]),
                        "gist": t.get("gist", ""), "phrase": t.get("phrase", ""), "items": t.get("items", []),
                        "level": t.get("level")})
        except Exception:
            continue
    return res


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--run", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--app-only", action="store_true", help="judge only the app's tips (the skill's were judged before)")
    a = ap.parse_args(argv)
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    lines = load_call(a.md, cfg["me_label"])
    stem = a.md.name[:-3]
    skill = [] if a.app_only else tips_of(a.md.parent / (stem + ".tips.jsonl"), "skill")
    app = tips_of(a.run / (stem + ".app.tips.jsonl"), "app")
    t0, t1 = (min(l.written for l in lines if l.written), max(l.written for l in lines if l.written))
    items = [t for t in skill + app if t0 - 60 <= t["src_s"] <= t1]
    random.Random(7).shuffle(items)
    prov = make_provider(cfg, lambda n: load_secret(n, cfg.get("secrets_file")))
    a.out.mkdir(parents=True, exist_ok=True)
    outp = a.out / "judge.jsonl"
    extra = {"extra_body": {"thinking": {"type": "adaptive"}, "output_config": {"effort": "low"}}}
    for it in items:
        hint = "gist: {}\nphrase: {}\nitems: {}".format(it["gist"], it["phrase"], "; ".join(str(x) for x in it["items"]))
        user = "TRANSCRIPT (trigger line marked; hint shown at {}):\n{}\n\nHINT:\n{}".format(
            "{:02d}:{:02d}:{:02d}".format(int(it["at_s"]) // 3600, int(it["at_s"]) % 3600 // 60, int(it["at_s"]) % 60),
            window(lines, it["src_s"], it["at_s"]), hint)
        c = prov.complete(model=a.model, system=[{"text": SYSTEM, "cache": True}], user=user, max_tokens=400,
                          cache_ttl="5m", extra=extra)
        obj = first_json(c.text) or {}
        rec = dict(it, score=obj.get("score"), timely=obj.get("timely"), concrete=obj.get("concrete"),
                   reason=obj.get("reason"), error=c.error)
        with outp.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    summary = {}
    for eng in ("skill", "app"):
        sc = [r["score"] for r in jl(outp) if r["engine"] == eng and isinstance(r.get("score"), (int, float))]
        good = [s for s in sc if s >= 4]
        summary[eng] = {"n": len(sc), "mean": round(sum(sc) / len(sc), 2) if sc else None, "p50": pct(sc, .5),
                        "share_4plus": round(len(good) / len(sc), 2) if sc else None,
                        "timely": round(sum(1 for r in jl(outp) if r["engine"] == eng and r.get("timely")) / len(sc), 2) if sc else None}
    (a.out / "judge.summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
