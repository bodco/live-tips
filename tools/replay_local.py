#!/usr/bin/env python3
"""Replay the recorder's local layer on a recorded call: keyword facts and cards, the instant "❓" items,
semantic facts and cards. Same classes, same thresholds and the same embedding model as a live call;
no audio, no Whisper, no Claude. The model engine has its own replay (livetips_m0.replay).

  python3 tools/replay_local.py --md <live>/<stem>.md --out <dir>
      [--timing <stem>.md.timing.jsonl] [--facts <stem>.facts.json] [--cards <stem>.cards.json]
      [--config <work>/Tools/LiveTips/config.json] [--set semantic_fact_min=0.55 ...]
      [--embed-url http://127.0.0.1:11435 | --model-dir <app root>/models/bge-m3-int8]
      [--call-type auto] [--compare]

Lines come from the transcript (<stem>.md as written live; <stem>.named.md works too) and are fed in the
order and at the moment the recorder saw them (`written` in the timing sidecar). The replay clock replaces
the wall clock, so cooldowns and the topic window behave as they did live.

Writes into --out (keep it outside the repository: it holds call text):
  <stem>.local-tips.jsonl      what the window would show (src = line time, at = shown)
  <stem>.local.semantic.jsonl  every semantic decision with its reason (shown or why not)
  <stem>.local-report.md       shows, rejections by reason and, with --compare, live vs replay
  <stem>.local-summary.json    the same numbers for scripts and checks
  <stem>.replay-line-vectors.npz  line vectors (one line per request, as live), so a rerun embeds nothing new

--compare reads the live <stem>.tips.jsonl and <stem>.semantic.jsonl next to --md.
--embed-url talks to the running engine (the app's built-in one or Ollama); --model-dir runs the same
ONNX model in-process (spikes/m0/livetips_m0/embed_server.Engine) where no server is reachable."""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import re
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "recorder" / "src"))
import semantic as SEM  # noqa: E402
import transcriber as T  # noqa: E402

LOCAL_KINDS = ("fact", "card", "question")
LINE_RX = re.compile(r"^\[(\d{2}:\d{2}:\d{2})\]\s+(.+?)\s+\(([\w-]+)\):\s?(.*)$")
ME_LABELS = {"Я", "Me"}


# --------------------------------------------------------------------------- clock

class Clock:
    """The replay time. transcriber.now() reads it while the replay runs."""

    def __init__(self, t: float = 0.0):
        self.t = float(t)

    def __call__(self) -> float:
        return self.t


def install_clock(clock: Clock):
    old = T.now
    T.now = clock
    return old


# --------------------------------------------------------------------------- input

class RLine:
    __slots__ = ("t", "written", "ch", "lang", "text", "hms")

    def __init__(self, t: float, written: float, ch: str, lang: str, text: str, hms: str):
        self.t, self.written, self.ch, self.lang, self.text, self.hms = t, written, ch, lang, text, hms


def _epoch(date: str, hms: str) -> float:
    frac = ""
    if "." in hms:
        hms, frac = hms.split(".", 1)
    t = dt.datetime.strptime(f"{date} {hms}", "%Y-%m-%d %H:%M:%S").timestamp()
    return t + (float("0." + frac) if frac.isdigit() else 0.0)


def parse_transcript(text: str) -> tuple[str | None, set[str], list[tuple[str, str, str, str]]]:
    """(date, labels of the PM's own channel, [(hh:mm:ss, label, lang, text)]) of a live transcript."""
    date, me = None, set(ME_LABELS)
    rows = []
    for raw in text.splitlines():
        m = re.match(r"^- Start:\s*(\d{4}-\d{2}-\d{2})", raw)
        if m and date is None:
            date = m.group(1)
        m = re.match(r"^- Channels:\s*(.+?)\s*=\s*microphone", raw)
        if m:
            me.add(m.group(1).strip())
        m = LINE_RX.match(raw)
        if m and m.group(4).strip():
            rows.append((m.group(1), m.group(2).strip(), m.group(3), m.group(4).strip()))
    return date, me, rows


def channel_of(label: str, me: set[str]) -> str:
    return "me" if label in me or label.split(" [")[0] in me else "them"


def load_lines(md: Path, timing: Path | None, date: str | None = None) -> list[RLine]:
    """Transcript lines with the moment the recorder had each one (timing `written`), in that order.
    A line without a timing row is taken as written 1 s after it started."""
    d, me, rows = parse_transcript(md.read_text(encoding="utf-8"))
    date = date or d or dt.date.today().isoformat()
    slots: dict[tuple[str, str], list[dict]] = collections.defaultdict(list)
    for r in T._read_jsonl(timing) if timing else []:
        if r.get("t") and r.get("ch"):
            slots[(str(r["t"]), str(r["ch"]))].append(r)
    out, prev = [], None
    for hms, label, lang, text in rows:
        ch = channel_of(label, me)
        t = _epoch(date, hms)
        if prev is not None and t < prev - 12 * 3600:      # the call went past midnight
            t += 86400
        prev = t
        row = slots[(hms, ch)].pop(0) if slots.get((hms, ch)) else None
        written = t + 1.0
        if row and row.get("written"):
            written = _epoch(date, str(row["written"]))
            if written < t - 60:
                written += 86400
        out.append(RLine(t, written, ch, lang, text, hms))
    out.sort(key=lambda x: (x.written, x.t))
    return out


# --------------------------------------------------------------------------- embeddings

class ReplayClient:
    """The part of semantic.OllamaClient that SemanticLive uses, with a vector cache on disk.
    `embed_fn(texts) -> matrix` is the engine: the HTTP server or the in-process ONNX model."""

    def __init__(self, embed_fn, model: str = "bge-m3", cache_path: Path | None = None, version: str = "replay"):
        self.embed_fn, self.model, self.cache_path, self.ver = embed_fn, model, cache_path, version
        self.vc = SEM.load_vec_cache(cache_path, model) if cache_path else {}
        self.calls = self.texts = self.cached = self.errors = 0
        self.dirty = False

    def health(self, force: bool = False):
        return True, ""

    def mark_down(self, reason: str) -> None:
        pass

    def version(self) -> str:
        return self.ver

    def stats(self) -> dict:
        return {"calls": self.calls, "texts": self.texts, "cached": self.cached, "errors": self.errors}

    def embed(self, texts, timeout=None, use_cache: bool = True) -> np.ndarray:
        texts = [t if isinstance(t, str) else str(t) for t in texts]
        keys = [SEM.text_hash(t, self.model) for t in texts]
        miss = [i for i, k in enumerate(keys) if k not in self.vc]
        self.cached += len(texts) - len(miss)
        for j in range(0, len(miss), 32):           # semantic.OllamaClient sends up to 32 texts per request
            part = miss[j:j + 32]
            v = SEM.l2norm(np.asarray(self.embed_fn([texts[i] for i in part]), dtype=np.float32))
            self.calls += 1
            self.texts += len(part)
            for i, row in zip(part, v):
                self.vc[keys[i]] = row
            self.dirty = True
        if not texts:
            return np.zeros((0, 1024), dtype=np.float32)
        return np.stack([self.vc[k] for k in keys]).astype(np.float32)

    def seed(self, npz: Path) -> int:
        """Take vectors from another cache (the live call's <stem>.semantic.npz holds the fact, card and anchor
        vectors the Mac engine made). The int8 model gives slightly different vectors on another CPU
        (cosine ~0.985 between Apple Silicon and x86), so seeding keeps that noise out of the fact side."""
        got = SEM.load_vec_cache(npz, self.model)
        changed = any(k not in self.vc or not np.array_equal(self.vc[k], v) for k, v in got.items())
        self.vc.update(got)                  # the seed wins over vectors this machine made earlier
        self.dirty = self.dirty or changed
        return len(got)

    def save(self) -> None:
        if self.cache_path and self.dirty:
            SEM.save_vec_cache(self.cache_path, self.model, self.vc)
            self.dirty = False


def make_client(args, cfg: dict, cache_path: Path) -> ReplayClient:
    model = str(cfg.get("semantic_model") or "bge-m3")
    if args.model_dir:
        sys.path.insert(0, str(REPO / "spikes" / "m0"))
        from livetips_m0.embed_server import VERSION, Engine
        eng = Engine(Path(args.model_dir).expanduser())
        return ReplayClient(eng.embed, model, cache_path, VERSION + " (in-process)")
    url = args.embed_url or cfg.get("ollama_url") or SEM.DEFAULT_URL
    oc = SEM.OllamaClient(url, model, timeout=60.0)
    return ReplayClient(lambda tx: oc.embed(tx, timeout=60.0, use_cache=False), model, cache_path, f"{url}")


# --------------------------------------------------------------------------- the replay

def build_cfg(config: Path | None, sets: list[str]) -> dict:
    cfg = dict(T.DEFAULTS)
    if config and config.exists():
        cfg.update(json.loads(config.read_text(encoding="utf-8")))
    for s in sets or []:
        k, _, v = s.partition("=")
        try:
            cfg[k.strip()] = json.loads(v)
        except ValueError:
            cfg[k.strip()] = v
    return cfg


def run(lines: list[RLine], facts_path: Path | None, cards_path: Path | None, cfg: dict, client,
        out_dir: Path, stem: str, call_type: str = "auto", semantic: bool = True) -> dict:
    """Feed the lines through the local layer exactly as the recorder's process() does. Returns paths."""
    out_dir.mkdir(parents=True, exist_ok=True)
    tips = out_dir / f"{stem}.local-tips.jsonl"
    base = out_dir / f"{stem}.local.md"           # SemanticLive derives <stem>.local.semantic.jsonl / .npz from it
    for p in (tips, base.with_name(base.stem + ".semantic.jsonl"), out_dir / f"{stem}.local-cards-fired.jsonl"):
        if p.exists():
            p.write_text("", encoding="utf-8")      # truncate, not unlink: a rerun into the same folder
    clock = Clock(lines[0].written if lines else 0.0)
    old_now = install_clock(clock)
    old_meeting = dict(T.MEETING)
    try:
        T.MEETING.update(call_type=call_type, audience="auto")
        facts = T.FactBook(base, tips)
        facts.path = facts_path or Path("/nonexistent")
        cards = T.Cards(base, tips)
        cards.path = cards_path or Path("/nonexistent")
        cards.fired_path = out_dir / f"{stem}.local-cards-fired.jsonl"
        cards.names = [str(n) for n in cfg.get("name_aliases") or []]   # as the recorder's main loop sets it
        facts.refresh()
        cards.snapshot()
        flags = {"tips_paused": False, "tips_off": False}
        sem = None
        if semantic and client is not None:
            sem = T.SemanticLive(cfg, base, tips, facts, cards, flags, client)
            sem.vcache = {}                       # vectors come from the client (seeded), not a stale file of an earlier run
            sem._sync()
            sem.state = "on"
        names = cfg.get("name_aliases") or []
        min_words = int(cfg.get("semantic_min_words", T.DEFAULTS["semantic_min_words"]))
        for ln in lines:
            clock.t = ln.written
            line = T.Line(ln.ch, ln.t, ln.lang, ln.text)
            q = None
            if ln.ch == "them":
                q = T.question_item(ln.text, T.hhmmss(ln.t), T.hhmmss(clock.t), names)
                if q:
                    T._append_json(tips, q)
            cards.check(line)                     # the keyword path runs right after submit, before the embedding
            facts.check(line)
            if sem is not None and T.word_count(ln.text) >= min_words:
                clock.t = ln.written + 0.06       # live median embedding latency
                sem._process(line, q is not None)
    finally:
        T.now = old_now
        T.MEETING.clear()
        T.MEETING.update(old_meeting)
        if client is not None and hasattr(client, "save"):
            client.save()
    return {"tips": tips, "semantic": base.with_name(base.stem + ".semantic.jsonl")}


# --------------------------------------------------------------------------- report

def _title_ids(facts_path: Path | None) -> dict[str, str]:
    try:
        facts = T.parse_facts(json.loads(facts_path.read_text(encoding="utf-8"))) if facts_path else []
    except (OSError, ValueError):
        facts = []
    return {f["title"]: f["id"] for f in facts if f.get("title")}


def fact_keys(items: list, gist: str, title_ids: dict[str, str]) -> str:
    """Fact ids of a shown fact item ("title: text" lines); titles may contain ": " themselves."""
    titles = sorted(title_ids, key=len, reverse=True)
    out = []
    for it in items or [gist.replace("📌", "", 1).strip()]:
        it = str(it)
        t = next((x for x in titles if it == x or it.startswith(x + ": ")), it.split(": ", 1)[0])
        out.append(title_ids.get(t, t))
    return ",".join(out)


def shows(tips_path: Path, title_ids: dict[str, str]) -> list[dict]:
    """The local items a tips file showed: kind, key (card id, fact ids or the ❓ text), src, at, path."""
    out = []
    for r in T._read_jsonl(tips_path):
        k = r.get("kind")
        if k not in LOCAL_KINDS or not r.get("t"):
            continue
        gist = str(r.get("gist") or "")
        if k == "card":
            key = str(r.get("card") or "")
        elif k == "fact":
            key = fact_keys(r.get("items") or [], gist, title_ids)
        else:
            key = gist
        out.append({"kind": k, "key": key, "src": r.get("src") or r.get("t"), "at": r.get("at"),
                    "path": "semantic" if "sem" in r else "keyword", "sem": r.get("sem"), "gist": gist[:80]})
    return out


def rejections(sem_path: Path) -> collections.Counter:
    return collections.Counter((r.get("kind"), r.get("why") or "shown") for r in T._read_jsonl(sem_path)
                               if r.get("kind") in ("fact", "card"))


def compare(live: list[dict], rep: list[dict]) -> dict:
    """Pairs live and replay shows by kind, key and line time (src); facts also by any shared fact id."""
    def same(a, b):
        if a["kind"] != b["kind"] or a["src"] != b["src"]:
            return False
        if a["kind"] == "fact":
            return bool(set(a["key"].split(",")) & set(b["key"].split(",")))
        return a["key"] == b["key"]
    left = list(rep)
    matched, only_live = [], []
    for a in live:
        b = next((x for x in left if same(a, x)), None)
        if b is None:
            only_live.append(a)
        else:
            left.remove(b)
            matched.append((a, b))
    return {"matched": matched, "only_live": only_live, "only_replay": left}


def report(stem: str, rep: list[dict], rej: collections.Counter, cmp: dict | None, live_rej: collections.Counter | None,
           meta: dict) -> tuple[str, dict]:
    by_kind = collections.Counter(x["kind"] for x in rep)
    summ = {"stem": stem, "meta": meta, "shows": rep, "counts": dict(by_kind),
            "local_shows": by_kind["fact"] + by_kind["card"],
            "semantic_shows": sum(1 for x in rep if x["kind"] in ("fact", "card") and x["path"] == "semantic"),
            "rejections": {f"{k}|{w}": n for (k, w), n in sorted(rej.items())},
            "not_a_question": rej.get(("fact", "not a question, topic not held"), 0)}
    md = [f"# Local layer replay: {stem}", "",
          f"- engine: {meta.get('engine')}, call type: {meta.get('call_type')}, lines: {meta.get('lines')}, "
          f"seeded vectors: {meta.get('seeded_vectors')}",
          f"- thresholds: fact_min {meta.get('fact_min')}, margin {meta.get('margin')}, card_min {meta.get('card_min')}, "
          f"card_margin {meta.get('card_margin')}, topic window {meta.get('topic_s')} s", "",
          "## Shown", "", "| kind | key | src -> at | path | sem |", "|---|---|---|---|---|"]
    for x in rep:
        md.append(f"| {x['kind']} | {x['key'][:40]} | {x['src']} -> {x['at']} | {x['path']} | {x['sem'] or ''} |")
    md += ["", f"Facts and cards: {summ['local_shows']} ({by_kind['fact']} facts, {by_kind['card']} cards, "
           f"{summ['semantic_shows']} by meaning); "
           f"❓ items: {by_kind['question']}", "", "## Semantic decisions by reason", "",
           "| kind | reason | replay | live |", "|---|---|---|---|"]
    keys = sorted(set(rej) | set(live_rej or {}), key=lambda k: (k[0] or "", k[1] or ""))
    for k in keys:
        md.append(f"| {k[0]} | {k[1]} | {rej.get(k, 0)} | {(live_rej or {}).get(k, '') if live_rej is not None else ''} |")
    if cmp is not None:
        lc = collections.Counter(a["kind"] for a, _ in cmp["matched"]) + collections.Counter(a["kind"] for a in cmp["only_live"])
        live_all = [a for a, _ in cmp["matched"]] + cmp["only_live"]
        summ["live"] = {"counts": dict(lc), "local_shows": lc["fact"] + lc["card"],
                        "semantic_shows": sum(1 for x in live_all if x["kind"] in ("fact", "card") and x["path"] == "semantic"),
                        "matched": len(cmp["matched"]), "only_live": cmp["only_live"], "only_replay": cmp["only_replay"],
                        "not_a_question": (live_rej or {}).get(("fact", "not a question, topic not held"), 0)}
        md += ["", "## Live vs replay", "",
               f"- live facts+cards {summ['live']['local_shows']} (semantic {summ['live']['semantic_shows']}), "
               f"replay {summ['local_shows']} (semantic {summ['semantic_shows']}); "
               f"matched {len(cmp['matched'])} of {sum(lc.values())} live items (all kinds)",
               f"- 'not a question, topic not held': live {summ['live']['not_a_question']}, replay {summ['not_a_question']}", ""]
        for title, rows in (("Only live", cmp["only_live"]), ("Only replay", cmp["only_replay"])):
            md.append(f"### {title}: {len(rows)}")
            md += [f"- {x['kind']} {x['key'][:40]} {x['src']} ({x['path']})" for x in rows] or ["- none"]
            md.append("")
    return "\n".join(md) + "\n", summ


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--timing", type=Path)
    ap.add_argument("--facts", type=Path)
    ap.add_argument("--cards", type=Path)
    ap.add_argument("--config", type=Path)
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument("--embed-url")
    ap.add_argument("--model-dir")
    ap.add_argument("--seed-vectors", type=Path, help="vector cache to reuse (default: the live <stem>.semantic.npz)")
    ap.add_argument("--no-seed", action="store_true")
    ap.add_argument("--call-type", default="auto")
    ap.add_argument("--no-semantic", action="store_true")
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args(argv)
    md = a.md.expanduser()
    stem = md.name[:-len(".named.md")] if md.name.endswith(".named.md") else md.stem
    sib = lambda suf: md.with_name(stem + suf)  # noqa: E731
    timing = a.timing or (sib(".md.timing.jsonl") if sib(".md.timing.jsonl").exists() else None)
    facts = a.facts or (sib(".facts.json") if sib(".facts.json").exists() else None)
    cards = a.cards or (sib(".cards.json") if sib(".cards.json").exists() else None)
    cfg = build_cfg(a.config.expanduser() if a.config else None, a.set)
    out = a.out.expanduser()
    out.mkdir(parents=True, exist_ok=True)
    client = None if a.no_semantic else make_client(a, cfg, out / f"{stem}.replay-line-vectors.npz")
    seeded = 0
    seed = a.seed_vectors or sib(".semantic.npz")
    if client is not None and not a.no_seed and seed.exists():
        seeded = client.seed(seed.expanduser())
    lines = load_lines(md, timing)
    if client is not None:
        # One line per request, as live: the int8 model quantizes each request as a whole, so a line embedded in a
        # batch with others gets a slightly different vector (scores moved by up to 0.03 and changed what showed).
        for x in lines:
            if T.word_count(x.text) >= int(cfg.get("semantic_min_words", 3)):
                client.embed([x.text])
    paths = run(lines, facts, cards, cfg, client, out, stem, a.call_type, semantic=client is not None)
    tid = _title_ids(facts)
    rep = shows(paths["tips"], tid)
    rej = rejections(paths["semantic"])
    cmp = live_rej = None
    if a.compare and sib(".tips.jsonl").exists():
        cmp = compare(shows(sib(".tips.jsonl"), tid), rep)
        live_rej = rejections(sib(".semantic.jsonl"))
    f = lambda k: cfg.get(k, T.DEFAULTS.get(k))  # noqa: E731
    meta = {"engine": client.version() if client else "off", "call_type": a.call_type, "lines": len(lines),
            "timing": bool(timing), "seeded_vectors": seeded, "fact_min": f("semantic_fact_min"), "margin": f("semantic_margin"),
            "card_min": f("semantic_card_min"), "card_margin": f("semantic_card_margin"), "topic_s": f("semantic_topic_s")}
    text, summ = report(stem, rep, rej, cmp, live_rej, meta)
    (out / f"{stem}.local-report.md").write_text(text, encoding="utf-8")
    (out / f"{stem}.local-summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1), encoding="utf-8")
    line = (f"replay_local: {len(lines)} lines, facts+cards {summ['local_shows']} (semantic {summ['semantic_shows']}), "
            f"not-a-question {summ['not_a_question']}")
    if "live" in summ:
        line += (f" | live {summ['live']['local_shows']} (semantic {summ['live']['semantic_shows']}) / "
                 f"{summ['live']['not_a_question']}, matched {summ['live']['matched']},"
                 f" only live {len(summ['live']['only_live'])}, only replay {len(summ['live']['only_replay'])}")
    print(line)
    print(f"report: {out / (stem + '.local-report.md')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
