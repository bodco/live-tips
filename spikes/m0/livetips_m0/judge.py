"""Blind quality judge: scores every tip of the skill and of the app on the same call.

Each tip is judged alone, with the transcript from 90 s before its trigger line to 20 s after it
was shown, without saying which engine wrote it. Order is shuffled. Output: one JSON line per tip
in <out>/judge.jsonl and a summary (per engine, with the worst 3 reasons) in <out>/judge.summary.json.

  python -m livetips_m0.judge --config cfg.json --md <call>.md --run runs/<run> --out runs/judge-<name>
  python -m livetips_m0.judge --config cfg.json --md <call>.md --app-tips <tips.jsonl> --call-type presentation \
      --slides slides.json --quick          # post-call run of the app: Sonnet, at most 25 tips

The rubric follows the call type: for a presentation the judge gets the slide plan (timing and
pacing tips are judged against it, silence while the PM presents is correct); for an interview the
tips are judged for the PM's role (--role).
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

OPUS = "claude-opus-5-5"
QUICK_MODEL = "claude-sonnet-5-5"
QUICK_MAX = 25

SYSTEM = """You evaluate live hints shown to a project manager (PM) in a small window during a video call.
Score ONE hint from 1 to 5:
5 = exactly what the PM needed at that moment: concrete (fact, number, owner, date or a ready sentence), correct per the transcript, shown before the PM had to answer.
4 = useful and timely, minor issues.
3 = somewhat useful, or useful but late (the PM already answered or the topic moved on).
2 = generic, mostly redundant, or about a different topic than the live one.
1 = wrong, misleading, or noise.
Judge only from the transcript; you cannot see the documents the hint may cite, so do not penalise a cited fact you cannot verify unless the transcript contradicts it.
Return JSON only: {"score": 1-5, "timely": true|false, "concrete": true|false, "reason": "<max 15 words>"}"""

PRESENTATION = """
CALL TYPE: presentation. The PM and possibly colleagues present slides by a plan (below).
Judge timing and slide-pacing hints against this plan, not only against the transcript: a hint about time left, the next slide or a handoff is correct when it matches the plan and the moment, even if nobody says it aloud.
A pacing hint shown while a colleague presents their own slides is useless to the PM (score 2 at most).
Silence while the PM presents is correct: a hint that interrupts the PM's own flow without a needed fact or number is noise.
SLIDE PLAN (n | title | who | sec):
{plan}"""

INTERVIEW = """
CALL TYPE: interview. Judge each hint for the PM's role in this interview{role}: a good hint helps the PM ask a sharper follow-up, check a claim or keep the interview on its plan; it does not answer for the candidate."""


def _hms(s):
    s = int(s)
    return "{:02d}:{:02d}:{:02d}".format(s // 3600, s % 3600 // 60, s % 60)


def window(lines, src_s, shown_s):
    out = []
    for ln in lines:
        if src_s - 90 <= ln.t_s <= shown_s + 20:
            mark = "  <-- trigger line" if ln.t == _hms(src_s) else ""
            out.append("[{}] {}: {}{}".format(ln.t, "PM" if ln.speaker == "me" else (ln.stag or "Other"), ln.text, mark))
    return "\n".join(out)


def tips_of(path: Path, engine: str, skip_engine: str = None):
    """Shown tips of one engine. Skips partial items, retract records and every uid that was retracted."""
    recs = jl(path) if path else []
    retracted = {r.get("uid") for r in recs if r.get("kind") == "retract" and r.get("uid")}
    res = []
    for t in recs:
        if t.get("kind") not in ("tip", "fact", "answer") or t.get("q") or t.get("partial") or "src" not in t or "at" not in t:
            continue
        if t.get("uid") and t.get("uid") in retracted:
            continue
        if skip_engine and t.get("engine") == skip_engine:
            continue
        try:
            res.append({"engine": engine, "src_s": hms_to_s(t["src"][:8]), "at_s": hms_to_s(t["at"][:8]),
                        "gist": t.get("gist", ""), "phrase": t.get("phrase", ""), "items": t.get("items", []),
                        "level": t.get("level")})
        except Exception:
            continue
    return res


def load_slides(path):
    """slides.json: a list or {"slides": [...]}; each slide has n, title, who (or speaker), sec."""
    if not path or not Path(path).exists():
        return []
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except ValueError:
        return []
    sl = d.get("slides", []) if isinstance(d, dict) else d
    return [s for s in sl if isinstance(s, dict)]


def compact_plan(slides, limit=60):
    rows = []
    for i, s in enumerate(slides[:limit]):
        rows.append("{} | {} | {} | {}".format(s.get("n", i + 1), str(s.get("title", ""))[:60],
                                               s.get("who") or s.get("speaker") or "?", s.get("sec", "?")))
    return "\n".join(rows) if rows else "(no plan given)"


def system_prompt(call_type="auto", slides=None, role=""):
    if call_type == "presentation":
        return SYSTEM + PRESENTATION.format(plan=compact_plan(slides or []))
    if call_type == "interview":
        return SYSTEM + INTERVIEW.format(role=(" (role: " + role + ")") if role else "")
    return SYSTEM


def resolve_call_type(a, cfg):
    ct = a.call_type
    if ct == "auto":
        ct = str(cfg.get("call_type") or "").lower()
        if "present" in ct:
            ct = "presentation"
        elif "interview" in ct or "hiring" in ct:
            ct = "interview"
        elif a.slides:
            ct = "presentation"
        else:
            ct = "auto"
    return ct


def sample_even(items, n):
    """At most n items spread evenly over the call (items sorted by time)."""
    items = sorted(items, key=lambda t: t["at_s"])
    if len(items) <= n:
        return items
    step = len(items) / float(n)
    return [items[int(i * step)] for i in range(n)]


def summarize(recs):
    summary = {}
    for eng in ("skill", "app"):
        rs = [r for r in recs if r["engine"] == eng and isinstance(r.get("score"), (int, float))]
        sc = [r["score"] for r in rs]
        good = [s for s in sc if s >= 4]
        worst = sorted(rs, key=lambda r: r["score"])[:3]
        summary[eng] = {"n": len(sc), "mean": round(sum(sc) / len(sc), 2) if sc else None, "p50": pct(sc, .5),
                        "share_4plus": round(len(good) / len(sc), 2) if sc else None,
                        "timely": round(sum(1 for r in rs if r.get("timely")) / len(sc), 2) if sc else None,
                        "worst": ["{} ({}): {}".format(r["score"], (r.get("gist") or "")[:40], r.get("reason") or "")
                                  for r in worst if r["score"] <= 3]}
    return summary


def main(argv=None, provider=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--run", type=Path, help="run dir with <stem>.app.tips.jsonl")
    ap.add_argument("--app-tips", type=Path, help="the app's tips file (instead of --run)")
    ap.add_argument("--out", type=Path, help="default: <transcript dir>/<stem>.judge")
    ap.add_argument("--model", default=None)
    ap.add_argument("--app-only", action="store_true", help="judge only the app's tips (the skill's were judged before)")
    ap.add_argument("--call-type", default="auto", choices=["auto", "presentation", "interview"])
    ap.add_argument("--slides", type=Path, help="slides.json (plan: n, title, who, sec) for the presentation rubric")
    ap.add_argument("--role", default="", help="PM's role for the interview rubric")
    ap.add_argument("--quick", action="store_true", help="Sonnet, at most 25 tips sampled evenly (post-call run)")
    a = ap.parse_args(argv)
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    model = a.model or (QUICK_MODEL if a.quick else OPUS)
    lines = load_call(a.md, cfg.get("me_label", "Me"))
    stem = a.md.name[:-3] if a.md.name.endswith(".md") else a.md.stem
    out = a.out or (a.md.parent / (stem + ".judge"))
    app_path = a.app_tips or (a.run / (stem + ".app.tips.jsonl") if a.run else None)
    skill_path = a.md.parent / (stem + ".tips.jsonl")
    if stem.endswith(".app"):              # the app's own recording: the skill's tips of the same call, if any
        alt = a.md.parent / (stem[:-4] + ".tips.jsonl")
        if alt.exists():
            skill_path = alt
    same = app_path is not None and skill_path.exists() and app_path.exists() and \
        skill_path.resolve() == app_path.resolve()
    skill = [] if (a.app_only or same) else tips_of(skill_path, "skill")
    app = tips_of(app_path, "app", skip_engine="skill") if app_path else []
    ws = [l.written for l in lines if l.written] or [l.t_s for l in lines]
    if ws:
        t0, t1 = min(ws), max(ws)
        items = [t for t in skill + app if t0 - 60 <= t["src_s"] <= t1 + 60]
    else:
        items = skill + app
    if a.quick:
        ap_, sk_ = [t for t in items if t["engine"] == "app"], [t for t in items if t["engine"] == "skill"]
        n_app = min(len(ap_), max(QUICK_MAX - len(sk_), (QUICK_MAX + 1) // 2))   # half each, the rest to whoever has more
        items = sample_even(ap_, n_app) + sample_even(sk_, QUICK_MAX - n_app)
    random.Random(7).shuffle(items)
    call_type = resolve_call_type(a, cfg)
    system = system_prompt(call_type, load_slides(a.slides), a.role or str(cfg.get("hiring_role") or ""))
    prov = provider or make_provider(cfg, lambda n: load_secret(n, cfg.get("secrets_file")))
    out.mkdir(parents=True, exist_ok=True)
    outp = out / "judge.jsonl"
    if outp.exists():
        outp.write_text("")               # a rerun replaces the old scores
    extra = {"extra_body": {"thinking": {"type": "adaptive"}, "output_config": {"effort": "low"}}}
    if a.quick:
        extra = {"extra_body": {"thinking": {"type": "between_tools"}}}   # Sonnet 5.5 refuses "disabled" (400)
    recs = []
    for it in items:
        hint = "gist: {}\nphrase: {}\nitems: {}".format(it["gist"], it["phrase"], "; ".join(str(x) for x in it["items"]))
        user = "TRANSCRIPT (trigger line marked; hint shown at {}):\n{}\n\nHINT:\n{}".format(
            _hms(it["at_s"]), window(lines, it["src_s"], it["at_s"]), hint)
        c = prov.complete(model=model, system=[{"text": system, "cache": True}], user=user, max_tokens=400,
                          cache_ttl="5m", extra=extra)
        obj = first_json(c.text) or {}
        rec = dict(it, score=obj.get("score"), timely=obj.get("timely"), concrete=obj.get("concrete"),
                   reason=obj.get("reason"), error=c.error)
        recs.append(rec)
        with outp.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    summary = summarize(recs)
    summary["meta"] = {"model": model, "quick": a.quick, "call_type": call_type, "judged": len(recs)}
    (out / "judge.summary.json").write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    print(json.dumps(summary, ensure_ascii=False))
    return summary


if __name__ == "__main__":
    main()
