"""Offline audit of recorded semantic facts. No model calls, no production threshold mutation.

python -m livetips_m0.fact_quality --corpus private.json --holdout-date YYYY-MM-DD
Corpus rows: call, judge, tip; optional human: {useful: bool, reason: str}.
Judge labels are provisional; missing or disputed labels never become negatives.
"""
import argparse
import json
from pathlib import Path


def useful(row):
    human = row.get("human", {})
    if isinstance(human.get("useful"), bool):
        return human["useful"]
    score = row.get("judge", {}).get("score")
    return score >= 4 if isinstance(score, (int, float)) else None


def measures(rows, threshold):
    labeled = [r for r in rows if useful(r) is not None]
    accepted = [r for r in labeled if r["tip"]["sem"] >= threshold]
    good = sum(useful(r) for r in labeled)
    retained = sum(useful(r) for r in accepted)
    bad = len(labeled) - good
    return {"labeled": len(labeled), "good": good, "shown": len(accepted),
            "good_retained": retained, "good_lost": good - retained,
            "noise_removed": bad - (len(accepted) - retained),
            "precision": retained / len(accepted) if accepted else None,
            "good_retention": retained / good if good else None}


def threshold_audit(rows, holdout_date):
    semantic = [r for r in rows if isinstance(r.get("tip", {}).get("sem"), (int, float))]
    train = [r for r in semantic if r["call"][:10] < holdout_date]
    holdout = [r for r in semantic if r["call"][:10] >= holdout_date]
    grid = [{"threshold": t, "train": measures(train, t), "holdout": measures(holdout, t)}
            for t in (.55, .575, .60, .625, .65)]
    choice = choose_threshold(grid)
    human_complete = bool(semantic) and all(isinstance(r.get("human", {}).get("useful"), bool) for r in semantic)
    ready = passes_holdout(choice, human_complete)
    return {"semantic_rows": len(semantic), "excluded_nonsemantic_or_unmatched": len(rows) - len(semantic),
            "train_calls": sorted({r["call"] for r in train}), "holdout_calls": sorted({r["call"] for r in holdout}),
            "labels": "human" if human_complete else "provisional_judge_or_mixed",
            "candidate": choice["threshold"] if choice else None, "passes_labeled_sample": ready, "ready_for_production": False,
            "grid": grid, "limitation": "Shown-card sample only: cannot estimate recall of unshown facts. Validate relevance, novelty, source freshness and audience before promotion."}


def choose_threshold(grid):
    # Select on development calls only. Holdout never chooses the threshold.
    safe = [g for g in grid if g["train"]["good"] and not g["train"]["good_lost"]]
    return max(safe, key=lambda g: (g["train"]["noise_removed"], -g["threshold"])) if safe else None


def passes_holdout(choice, human_complete):
    return bool(choice and human_complete and choice["holdout"]["good"] and not choice["holdout"]["good_lost"])


def recorded_corpus(stems):
    """Join judge rows to actual shown facts by exact gist and source time, never fuzzy joins."""
    from .report import jl
    from .transcript import hms_to_s
    rows = []
    for stem in stems:
        tips = jl(Path(str(stem) + ".tips.jsonl"))
        for judge in jl(Path(str(stem) + ".judge/judge.jsonl")):
            if not judge.get("gist", "").startswith("📌"):
                continue
            matches = [t for t in tips if t.get("kind") == "fact" and t.get("gist") == judge["gist"]
                       and hms_to_s(t.get("src", t.get("t", "00:00:00"))) == judge.get("src_s")]
            rows.append({"call": stem.name, "judge": judge, "tip": matches[0] if len(matches) == 1 else {}})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--corpus", type=Path)
    source.add_argument("--calls", nargs="+", type=Path, help="Call stems, without .tips.jsonl")
    ap.add_argument("--holdout-date", required=True)
    args = ap.parse_args()
    rows = json.loads(args.corpus.read_text()) if args.corpus else recorded_corpus(args.calls)
    print(json.dumps(threshold_audit(rows, args.holdout_date), indent=2))


if __name__ == "__main__":
    main()
