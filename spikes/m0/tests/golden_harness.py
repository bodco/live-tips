"""Pins what the tips engine does (ub-mode "Refactoring: pin what the code does").

The engine runs over the demo call with a scripted model, a manual clock and a pool that runs submitted work
in submission order after each line, so the run is deterministic. Its outputs (tips, timing spans, model
requests) are compared with the snapshots in tests/golden/. Regenerate only on a deliberate behaviour change:
    python tests/golden_harness.py --write
"""
import hashlib
import json
import sys
from concurrent.futures import Future
from pathlib import Path

HERE = Path(__file__).absolute()
sys.path.insert(0, str(HERE.parents[1]))
FIX = HERE.parents[3] / "Fixtures"
GOLD = HERE.parent / "golden"

import threading                                        # noqa: E402
import types                                            # noqa: E402

import livetips_m0.engine as engine_mod                 # noqa: E402
from livetips_m0.providers import FakeProvider          # noqa: E402
from livetips_m0.replay import build_engine              # noqa: E402
from livetips_m0.transcript import load_call             # noqa: E402

BASE = {"variant": "golden", "models": {"classify": "fake-haiku", "tip": "fake-sonnet"}, "cache_ttl": "1h",
        "me_label": "Me", "them_label": "Other", "name_aliases": ["Alex"], "langs": ["en"], "tips_lang": "en",
        "active_rate_seconds": 45, "periodic_classify_s": 20, "hedge": {"enabled": False},
        "budget": {"ledger": "", "call_soft_usd": 1, "call_hard_usd": 2, "monthly_hard_usd": 100}}

VARIANTS = {
    "classic": dict(answer_any=False, turn_tips=True, speech_card=False, situation=False, proactive=True,
                    red_burst_s=0, phrase_repeat_min=1.1),
    "defaults": dict(situation=True, speech_card=True),
    "proactive": dict(situation=True, proactive=True, answer_any=True),
    "observer": dict(call_type="interview", hiring_role="observer", situation=True),
    "interviewer": dict(call_type="interview", hiring_role="interviewer", situation=True),
    "coach": dict(call_type="interview", hiring_role="coach"),
    "presentation": dict(call_type="presentation", situation=True),
    "team": dict(audience="team", situation=True, proactive=True),
    "client": dict(audience="client", situation=True),
}
REQUESTS = {6: ("ask", "When does the pilot start?"), 14: ("sos", ""), 22: ("ask", "What did we promise on retention?"),
            40: ("find", "pilot users"), 60: ("ask", "What is the release date?")}


def _h(text: str) -> int:
    return int(hashlib.sha1(text.encode()).hexdigest()[:8], 16)


def responder(model, user):
    h = _h(user)
    if "PREVIOUS STATE" in user:
        return json.dumps({"topic": "release plan", "owner": "Dana", "mine": h % 2 == 0, "floor": "Dana",
                           "asks": [{"id": "a%d" % (h % 3), "t": "10:00:05", "who": "Dana", "what": "send the test accounts",
                                     "type": "request"}] if h % 3 == 0 else [],
                           "actions": [{"id": "m1", "what": "confirm pilot users", "due": "Friday", "from": "PM"}],
                           "decisions": ["export goes live on Tuesday"], "speech_done": [0] if h % 4 == 0 else []})
    if "ROLE classify" in user:
        trig = ["add_fact", "direct_question", "your_turn", "new_requirement", "pm_commitment", "none"][h % 6]
        return json.dumps({"need_tip": trig != "none", "level": ["orange", "red", "info"][h % 3], "trigger": trig,
                           "topic": "topic %d" % (h % 5), "reason": "scripted"})
    if "queries" in user.lower() and "Question:" in user:
        return json.dumps({"queries": ["pilot start", "retention"]})
    if h % 7 == 0:
        return "not json at all"
    if h % 5 == 0:
        return json.dumps({"skip": True, "reason": "nothing"})
    return json.dumps({"gist": "Tip %d" % (h % 97), "level": ["red", "orange", "info"][h % 3],
                       "phrase": "We ship it on Tuesday, %d users." % (h % 9), "topic": "topic %d" % (h % 5),
                       "items": ["Review on Monday"], "fact_ids": ["F1"] if h % 2 else []})


class DeferredPool:
    """Runs submitted work later, in submission order, on the caller's thread."""

    def __init__(self):
        self.queue = []

    def submit(self, fn, *a, **k):
        f = Future()
        self.queue.append((f, fn, a, k))
        return f

    def run_all(self):
        while self.queue:
            f, fn, a, k = self.queue.pop(0)
            try:
                f.set_result(fn(*a, **k))
            except Exception as e:  # noqa: BLE001
                f.set_exception(e)

    def shutdown(self, wait=True):
        self.run_all()


class _Threads(types.SimpleNamespace):
    """threading with Thread(...).start() going to the deferred pool: the deep lookup runs in order too."""


def _deferred_threading(pool):
    ns = _Threads(**{k: getattr(threading, k) for k in dir(threading) if not k.startswith("__")})

    class T:
        def __init__(self, target=None, args=(), kwargs=None, daemon=None, **_):
            self.target, self.args, self.kwargs = target, args, kwargs or {}

        def start(self):
            pool.submit(self.target, *self.args, **self.kwargs)
    ns.Thread = T
    return ns


VOLATILE = ("_ms", "wall", "started", "updated", "elapsed")


def _clean(obj):
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in sorted(obj.items()) if not any(k.endswith(x) or k == x for x in VOLATILE)}
    if isinstance(obj, list):
        return [_clean(x) for x in obj]
    if isinstance(obj, float):
        return round(obj, 3)
    return obj


def run_variant(name: str, tmp: Path) -> dict:
    cfg = dict(BASE, **VARIANTS[name])
    cfg["budget"] = dict(BASE["budget"], ledger=str(tmp / "spend.json"))
    md = FIX / "golden-call.md"
    lines = load_call(md, "Me")
    for ln in lines:
        if ln.written is None:
            ln.seg_end = ln.t_s + (ln.dur or 3.0)
            ln.written = ln.seg_end + 1.0
    lines.sort(key=lambda x: x.written)
    clock = {"t": lines[0].written}
    prov = FakeProvider(responder)
    out = tmp / name
    eng, stem = build_engine(cfg, md, out, lambda: clock["t"], prov)
    pool = DeferredPool()
    eng.pool.shutdown(wait=False)
    eng.pool = pool
    real_threading = engine_mod.threading
    engine_mod.threading = _deferred_threading(pool)
    for i, ln in enumerate(lines):
        clock["t"] = ln.written
        eng.on_line(ln)
        pool.run_all()
        if i in REQUESTS:
            eng.on_request(*REQUESTS[i])
            pool.run_all()
    clock["t"] += 400
    if hasattr(eng, "final_wrapup"):
        eng.final_wrapup()
        pool.run_all()
    engine_mod.threading = real_threading
    res = {"requests": [{"model": c["model"], "user_sha": hashlib.sha1(c["user"].encode()).hexdigest()[:12]} for c in prov.calls]}
    for kind in ("tips", "timing", "llm"):
        p = out / (stem + ".app." + kind + ".jsonl")
        res[kind] = [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
    return _clean(res)


def main():
    import tempfile
    write = "--write" in sys.argv
    bad = 0
    for name in VARIANTS:
        with tempfile.TemporaryDirectory() as d:
            got = run_variant(name, Path(d))
        p = GOLD / (name + ".json")
        if write:
            GOLD.mkdir(exist_ok=True)
            p.write_text(json.dumps(got, ensure_ascii=False, indent=0, sort_keys=True))
        elif json.loads(p.read_text()) != got:
            bad += 1
            print("DIFF", name)
        print(name, {k: len(v) for k, v in got.items()})
    return bad


if __name__ == "__main__":
    sys.exit(main())
