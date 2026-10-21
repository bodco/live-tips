"""Latency of the skill's own tips on recorded calls (the baseline the app is compared with).

For each tip/fact/answer (typed window questions excluded) with `src` and `at`:
  at - src      : from the start of the trigger line (what the window shows)
  at - seg_end  : from the end of the trigger speech segment (comparable with the app's e2e)

  python -m livetips_m0.skill_baseline <live dir> [<live dir> ...]
"""
import argparse
import json
from pathlib import Path

from .report import jl, pct
from .transcript import hms_to_s


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+", type=Path)
    a = ap.parse_args(argv)
    all_src, all_end = [], []
    print("| Дзвінок | n | at-src p50 / p90 | at-seg_end p50 / p90 |")
    print("|---|---|---|---|")
    for d in a.dirs:
        for tf in sorted(d.glob("*.md.timing.jsonl")):
            stem = tf.name[:-len(".md.timing.jsonl")]
            tips = jl(d / (stem + ".tips.jsonl"))
            if not tips:
                continue
            timing = {}
            for r in jl(tf):
                timing.setdefault(r.get("t"), r)
            src_l, end_l = [], []
            for t in tips:
                if t.get("kind") not in ("tip", "fact", "answer") or t.get("q") or "src" not in t or "at" not in t:
                    continue
                try:
                    at, src = hms_to_s(t["at"][:8]), hms_to_s(t["src"][:8])
                except Exception:
                    continue
                if -5 < at - src < 300:
                    src_l.append(at - src)
                r = timing.get(t["src"][:8])
                if r and r.get("seg_end") and -5 < at - hms_to_s(r["seg_end"]) < 300:
                    end_l.append(at - hms_to_s(r["seg_end"]))
            all_src += src_l
            all_end += end_l
            print("| {} | {} | {} / {} | {} / {} |".format(stem, len(src_l), pct(src_l, .5), pct(src_l, .9), pct(end_l, .5), pct(end_l, .9)))
    print("| **Усього** | {} | {} / {} | {} / {} |".format(len(all_src), pct(all_src, .5), pct(all_src, .9), pct(all_end, .5), pct(all_end, .9)))


if __name__ == "__main__":
    main()
