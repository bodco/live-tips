"""Pure pieces of the situation tracker: they turn the model's JSON into the next state of the call.

The engine calls the model and owns the locks; everything here is plain data in, plain data out,
so it is tested without a model or threads.
"""
import re
from typing import List, Optional

WORD = re.compile(r"\w+", re.UNICODE)

ASK_TTL_S = 360          # an ask nobody answered for 6 minutes is old news (user review: one ask stayed red all call)
PM_WORDS_FOR_SPEECH = 8  # a speech point counts as said only when the PM really spoke (a replay struck it all through)


def jaccard(a: str, b: str) -> float:
    x, y = set(WORD.findall(a.lower())), set(WORD.findall(b.lower()))
    if not x or not y:
        return 0.0
    return len(x & y) / len(x | y)


def hms_to_s(t) -> Optional[int]:
    """'01:02:03' -> 3723; anything else -> None."""
    try:
        h, m, s = (int(v) for v in str(t).split(":"))
    except ValueError:
        return None
    return h * 3600 + m * 60 + s


def _dicts_with(items, *keys, limit: int) -> List[dict]:
    return [a for a in (items or []) if isinstance(a, dict) and all(a.get(k) for k in keys)][:limit]


def merge_risks(old: List[dict], heard) -> List[dict]:
    """Risks heard on the call stay until the end; a near-duplicate (Jaccard >= 0.5) is not added again."""
    out = list(old or [])
    for r in _dicts_with(heard, "what", limit=12):
        if not any(jaccard(r["what"], o.get("what", "")) >= 0.5 for o in out):
            out.append({"what": str(r["what"])[:160], "who": str(r.get("who") or "")[:40], "t": str(r.get("t") or "")[:8]})
    return out[:12]


def speech_done(prev: dict, claimed, pm_words: int) -> List[int]:
    done = set(prev.get("speech_done") or [])
    if pm_words >= PM_WORDS_FOR_SPEECH:
        done |= {int(i) for i in (claimed or []) if str(i).isdigit()}
    return sorted(done)


def ask_age(ask: dict, now_s: float) -> float:
    t = hms_to_s(ask.get("t"))
    return 0 if t is None else now_s - t


def fresh_asks(asks: List[dict], now_s: float, ttl_s: float) -> List[dict]:
    return [a for a in asks if ask_age(a, now_s) <= ttl_s]


def next_situation(obj: dict, prev: dict, pm_words: int, now_s: float, ask_ttl_s: float = ASK_TTL_S) -> dict:
    """The model's answer plus the previous state -> the new state of the call."""
    asks = _dicts_with(obj.get("asks"), "what", limit=6)
    return {"topic": str(obj.get("topic") or "")[:80], "owner": str(obj.get("owner") or "")[:40],
            "mine": bool(obj.get("mine")), "floor": str(obj.get("floor") or "")[:40],
            "asks": fresh_asks(asks, now_s, ask_ttl_s),
            "actions": _dicts_with(obj.get("actions"), "what", limit=20),
            "decisions": [str(d) for d in (obj.get("decisions") or []) if d][:20],
            "speech_done": speech_done(prev, obj.get("speech_done"), pm_words),
            # promises made earlier stay until the end of the call
            "theirs": _dicts_with(obj.get("theirs"), "what", "who", limit=20) or list(prev.get("theirs") or []),
            "risks": merge_risks(prev.get("risks"), obj.get("risks"))}
