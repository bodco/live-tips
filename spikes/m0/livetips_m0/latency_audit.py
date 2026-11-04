"""Compare pipeline clocks without conflating first gist, final response and UI paint.

python -m livetips_m0.latency_audit /path/to/*.timing.jsonl
Legacy e2e values without seg_end are not audio latency. UI paint is unmeasured.
"""
import argparse
import json
from pathlib import Path
from .report import jl, pct


def elapsed(end, start):
    if not isinstance(end, (int, float)) or not isinstance(start, (int, float)):
        return None
    delta = end - start
    return delta + 86400 if delta < -43200 else (delta if delta >= 0 else None)


def summarize(rows):
    stages = {k: [] for k in ("audio_to_transcript", "transcript_to_engine", "audio_to_first_gist", "audio_to_final", "tip_request_to_final")}
    missing = 0
    for row in rows:
        end = row.get("seg_end")
        missing += end is None
        pairs = {"audio_to_transcript": (row.get("written"), end),
                 "transcript_to_engine": (row.get("available_at"), row.get("written")),
                 "audio_to_first_gist": (row.get("shown_at"), end),
                 "audio_to_final": (row.get("emit_at"), end),
                 "tip_request_to_final": (row.get("emit_at"), row.get("tip_start"))}
        for key, pair in pairs.items():
            value = elapsed(*pair)
            if value is not None:
                stages[key].append(value)
    return {"events": len(rows), "missing_audio_end": missing, "ui_paint": "not measured",
            "stages": {k: {"n": len(v), "p50_s": pct(v, .5), "p90_s": pct(v, .9),
                           "max_s": max(v) if v else None, "over_20s": sum(x > 20 for x in v)} for k, v in stages.items()}}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="+", type=Path)
    args = ap.parse_args()
    print(json.dumps(summarize([r for p in args.files for r in jl(p) if r.get("outcome") == "emitted"]), indent=2))


if __name__ == "__main__":
    main()
