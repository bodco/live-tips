"""Offline evaluation of the local semantic layer (bge-m3 via Ollama) on recorded calls.

Uses live-transcriber's own semantic.py (imported read-only from --lt-src) so the numbers hold
for the code that runs on calls. Three steps:

  embed   : embed every transcript line (3+ words) one call at a time like the live path (latency),
            plus cards (gist + triggers), pseudo-facts (bullets of the call brief) and the neutral
            anchors; store top candidates per line with cosine and margin over the noise floor.
  label   : a strong model labels a stratified sample of (line, entry) pairs: would showing this
            entry right now help the PM? Also labels the keyword card fires (baseline).
  analyze : precision, estimated recall and hits per hour over a threshold grid.

  python -m livetips_m0.semantic_eval embed  --lt-src <live-transcriber/src> --out runs/sem --md <call.md> ...
  python -m livetips_m0.semantic_eval label  --config cfg.json --out runs/sem [--per-bin 25]
  python -m livetips_m0.semantic_eval analyze --out runs/sem
"""
import argparse
import json
import random
import re
import sys
import time
from pathlib import Path

import numpy as np

from .transcript import load_call

QUESTION_CUE = re.compile(
    r"\?|скільки|коли|як довго|термін|естімейт|оцінк|дедлайн|статус|ціна|вартіст|"
    r"how long|how much|how many|when|estimate|\beta\b|deadline|status|price|cost", re.I)
BINS = [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 1.01]


def _s(v):
    return "" if v is None else str(v).strip()


def _strs(v):
    if isinstance(v, str):
        return [v.strip()] if v.strip() else []
    return [str(x).strip() for x in (v or []) if str(x).strip()]


def card_sem_texts(c):
    """Same as live-transcriber transcriber.card_sem_texts (kept identical for parity)."""
    gist = re.sub(r"^\W+", "", _s(c.get("gist")))
    trig = [t for t in _strs(c.get("triggers")) if not t.startswith("re:")]
    out = []
    if gist or trig:
        out.append(". ".join([gist] + trig[:6]).strip(". "))
    out += [t for t in trig if len(t.split()) >= 2][:8]
    return [x for x in out if x]


def brief_facts(path: Path):
    """Pseudo fact book: bullet lines of the brief (proxy until calls with facts.json exist)."""
    out = []
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"\s*[-*]\s+(.*)$", raw)
        if m and 30 <= len(m.group(1)) <= 300:
            out.append({"id": "b{}".format(len(out)), "title": "", "text": m.group(1).strip()})
    return out


def word_count(t):
    return len(re.findall(r"\w+", t or ""))


def cmd_embed(a):
    sys.path.insert(0, str(a.lt_src))
    import semantic as SEM  # live-transcriber's module, read-only
    client = SEM.OllamaClient(model=a.model, timeout=2.0)
    ok, why = client.health(force=True)
    if not ok:
        raise SystemExit("Ollama not available: " + why)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    A = SEM.l2norm(client.embed(SEM.NEUTRAL_ANCHORS, timeout=30))
    lat = []
    for md in a.md:
        md = Path(md)
        stem = md.name[:-3]
        lines = [ln for ln in load_call(md, a.me_label) if word_count(ln.text) >= 3]
        cards_p = md.parent / (stem + ".cards.json")
        cards = []
        if cards_p.exists():
            data = json.loads(cards_p.read_text(encoding="utf-8"))
            cards = data if isinstance(data, list) else data.get("cards", [])
        ctexts, owner, cids, cons = [], [], [], []
        for c in cards:
            if not isinstance(c, dict) or c.get("off"):
                continue
            tx = card_sem_texts(c)
            if not tx:
                continue
            k = len(cids)
            cids.append(_s(c.get("id")) or "c{}".format(k))
            cons.append(c.get("on", "any"))
            ctexts += tx
            owner += [k] * len(tx)
        facts = brief_facts(md.parent / (stem + ".brief.md"))
        ftexts = [". ".join(x for x in (f["title"], f["text"]) if x) for f in facts]
        C = SEM.l2norm(client.embed(ctexts, timeout=60)) if ctexts else np.zeros((0, A.shape[1]), np.float32)
        F = SEM.l2norm(client.embed(ftexts, timeout=60)) if ftexts else np.zeros((0, A.shape[1]), np.float32)
        Cfl = (C @ A.T).max(1) if len(C) else np.zeros(0)
        Ffl = (F @ A.T).max(1) if len(F) else np.zeros(0)
        own = np.array(owner)
        cfloor = np.array([Cfl[own == k].max() for k in range(len(cids))]) if cids else np.zeros(0)
        rows = []
        for ln in lines:
            t0 = time.monotonic()
            try:
                v = SEM.l2norm(client.embed([ln.text], timeout=2.0, use_cache=False)[0])
            except Exception as e:
                rows.append({"line_id": ln.line_id, "error": str(e)[:100]})
                continue
            lat.append((time.monotonic() - t0) * 1000)
            rec = {"call": stem, "line_id": ln.line_id, "t": ln.t, "ch": ln.speaker, "text": ln.text[:300],
                   "q": bool(QUESTION_CUE.search(ln.text)), "cards": [], "facts": []}
            if cids:
                raw = C @ v
                best = np.full(len(cids), -1.0)
                np.maximum.at(best, own, raw)
                for k in np.argsort(-best)[:3]:
                    rec["cards"].append({"id": cids[int(k)], "on": cons[int(k)], "score": round(float(best[k]), 4),
                                         "over": round(float(best[k] - cfloor[k]), 4)})
            if len(F):
                s = F @ v
                for i in np.argsort(-s)[:3]:
                    rec["facts"].append({"id": facts[int(i)]["id"], "score": round(float(s[i]), 4),
                                         "over": round(float(s[i] - Ffl[i]), 4)})
            rows.append(rec)
        with (out / "candidates.jsonl").open("a", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        (out / (stem + ".entries.json")).write_text(json.dumps(
            {"cards": {cid: {"texts": [t for t, o in zip(ctexts, owner) if o == k], "on": cons[k]} for k, cid in enumerate(cids)},
             "facts": {f["id"]: f["text"] for f in facts}, "md": str(md)}, ensure_ascii=False, indent=1))
        print("embedded", stem, len(rows), "lines", len(cids), "cards", len(facts), "pseudo-facts", flush=True)
    lat.sort()
    mem = client.model_memory() if hasattr(client, "model_memory") else None
    stats = {"lines": len(lat), "latency_ms_p50": round(lat[len(lat) // 2], 1) if lat else None,
             "latency_ms_p90": round(lat[int(len(lat) * 0.9)], 1) if lat else None,
             "latency_ms_max": round(lat[-1], 1) if lat else None, "ollama_model_memory": mem}
    (out / "embed_stats.json").write_text(json.dumps(stats, indent=1))
    print(json.dumps(stats))


LABEL_SYS = """You label hints for a project manager (PM) on a live video call.
For each numbered item you get a transcript line (with a few lines before it) and a candidate entry from the PM's prepared notes (a card or a fact).
Answer: would showing this entry to the PM right now be useful, because the line is about the same concrete subject and the entry helps answer or act on it?
relevant = same concrete subject AND helpful now. Small talk, greetings, a merely related word, or a different subject = not relevant.
Return JSON only: {"labels": [{"n": <item number>, "relevant": true|false}, ...]}"""


def _context(lines_by_call, call, line_id, n=4):
    ls = lines_by_call[call]
    idx = next((i for i, ln in enumerate(ls) if ln.line_id == line_id), None)
    if idx is None:
        return ""
    return "\n".join("[{}] {}: {}".format(x.t, "PM" if x.speaker == "me" else "Other", x.text[:200])
                     for x in ls[max(0, idx - n):idx + 1])


def cmd_label(a):
    from .engine import first_json
    from .providers import make_provider
    from .secret_store import load_secret
    out = Path(a.out)
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    cands = [json.loads(l) for l in (out / "candidates.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    entries, lines_by_call = {}, {}
    for p in out.glob("*.entries.json"):
        e = json.loads(p.read_text(encoding="utf-8"))
        stem = p.name[:-len(".entries.json")]
        entries[stem] = e
        lines_by_call[stem] = load_call(Path(e["md"]), cfg["me_label"])
    pairs = []
    for c in cands:
        if "error" in c:
            continue
        for kind in ("cards", "facts"):
            if c[kind]:
                top = c[kind][0]
                if top["score"] >= BINS[0]:
                    pairs.append({"kind": kind[:-1], "call": c["call"], "line_id": c["line_id"], "ch": c["ch"], "q": c["q"],
                                  "id": top["id"], "score": top["score"], "over": top["over"], "on": top.get("on", "any"),
                                  "text": c["text"]})
    rnd = random.Random(11)
    sample = []
    for kind in ("card", "fact"):
        for lo, hi in zip(BINS[:-1], BINS[1:]):
            b = [p for p in pairs if p["kind"] == kind and lo <= p["score"] < hi]
            rnd.shuffle(b)
            pop = len(b)
            for p in b[:a.per_bin]:
                p["bin"] = lo
                p["weight"] = pop / max(1, min(pop, a.per_bin))
                sample.append(p)
    prov = make_provider(cfg, lambda n: load_secret(n, cfg.get("secrets_file")))
    extra = {"extra_body": {"thinking": {"type": "adaptive"}, "output_config": {"effort": "low"}}}
    res = []
    for i in range(0, len(sample), 10):
        chunk = sample[i:i + 10]
        items = []
        for n, p in enumerate(chunk, 1):
            e = entries[p["call"]]
            ent = " / ".join(e["cards"][p["id"]]["texts"][:2]) if p["kind"] == "card" else e["facts"][p["id"]]
            items.append("#{} TRANSCRIPT:\n{}\nENTRY ({}): {}".format(n, _context(lines_by_call, p["call"], p["line_id"]), p["kind"], ent[:400]))
        c = prov.complete(model=a.model, system=[{"text": LABEL_SYS, "cache": True}], user="\n\n".join(items),
                          max_tokens=2000, cache_ttl="5m", extra=extra)
        obj = first_json(c.text) or {}
        lab = {int(x.get("n", 0)): bool(x.get("relevant")) for x in obj.get("labels", []) if isinstance(x, dict)}
        for n, p in enumerate(chunk, 1):
            p["relevant"] = lab.get(n)
            res.append(p)
        print("labeled", len(res), "/", len(sample), flush=True)
    with (out / "labels.jsonl").open("w", encoding="utf-8") as f:
        for p in res:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")


def cmd_analyze(a):
    out = Path(a.out)
    labs = [json.loads(l) for l in (out / "labels.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    cands = [json.loads(l) for l in (out / "candidates.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    stats = json.loads((out / "embed_stats.json").read_text())
    calls = {}
    for c in cands:
        if "error" not in c:
            calls.setdefault(c["call"], []).append(c)
    hours = 0.0
    for cl in calls.values():
        ts = sorted(int(x["t"][:2]) * 3600 + int(x["t"][3:5]) * 60 + int(x["t"][6:8]) for x in cl)
        hours += max(60, ts[-1] - ts[0]) / 3600
    report = {"embed": stats, "hours": round(hours, 2), "kinds": {}}
    for kind in ("card", "fact"):
        L = [x for x in labs if x["kind"] == kind and x.get("relevant") is not None]
        if kind == "fact":
            L = [x for x in L if x["ch"] == "them"]          # facts fire on the other side's lines only
        pos_w = sum(x["weight"] for x in L if x["relevant"])
        grid = []
        for tmin in [0.45, 0.50, 0.525, 0.55, 0.575, 0.60, 0.625, 0.65, 0.70]:
            for m in [0.0, 0.04, 0.08, 0.10, 0.12]:
                sel = [x for x in L if x["score"] >= tmin and x["over"] >= m]
                w = sum(x["weight"] for x in sel)
                tp = sum(x["weight"] for x in sel if x["relevant"])
                prec = tp / w if w else None
                rec = tp / pos_w if pos_w else None
                per_h = w / hours if hours else None
                f1 = 2 * prec * rec / (prec + rec) if prec and rec else None
                grid.append({"min": tmin, "margin": m, "precision": round(prec, 3) if prec is not None else None,
                             "recall_est": round(rec, 3) if rec is not None else None, "f1": round(f1, 3) if f1 else None,
                             "shown_per_hour": round(per_h, 1) if per_h is not None else None,
                             "false_per_hour": round((w - tp) / hours, 1) if hours else None})
        bins = []
        for lo in BINS[:-1]:
            b = [x for x in L if x["bin"] == lo]
            if b:
                bins.append({"bin": lo, "n": len(b), "relevant_share": round(sum(1 for x in b if x["relevant"]) / len(b), 2)})
        report["kinds"][kind] = {"labeled": len(L), "bins": bins, "grid": grid}
    (out / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(json.dumps(report, ensure_ascii=False)[:4000])


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("embed")
    e.add_argument("--lt-src", required=True, type=Path)
    e.add_argument("--out", required=True)
    e.add_argument("--md", nargs="+", required=True)
    e.add_argument("--model", default="bge-m3")
    e.add_argument("--me-label", default="Я")
    l = sub.add_parser("label")
    l.add_argument("--config", required=True)
    l.add_argument("--out", required=True)
    l.add_argument("--per-bin", type=int, default=25)
    l.add_argument("--model", default="claude-opus-5-5")
    n = sub.add_parser("analyze")
    n.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    {"embed": cmd_embed, "label": cmd_label, "analyze": cmd_analyze}[a.cmd](a)


if __name__ == "__main__":
    main()
