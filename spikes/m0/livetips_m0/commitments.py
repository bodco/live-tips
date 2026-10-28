"""Commitments register (Pacenote 0.8, idea 01; rules/commitments.yaml).

One append-only JSON-lines file per project, next to the transcripts: <project>/live/commitments.jsonl.
The app's engine and the skill both write it; the register is the events folded by id. Nothing here talks to
the network.

  python -m livetips_m0.commitments list <live folder> [--all]
  python -m livetips_m0.commitments done <live folder> <id>
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import threading
from pathlib import Path
from typing import Dict, List, Optional

FILE = "commitments.jsonl"
WORD = re.compile(r"[\w']+", re.U)
_lock = threading.Lock()


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def call_key(call: str) -> str:
    """The call's transcript file name without folders, .md and the app's .app part (app and skill files match)."""
    n = Path(call or "").name
    for suf in (".md",):
        if n.endswith(suf):
            n = n[: -len(suf)]
    return n.replace(".app", "")


def series_key(project: str, title: str) -> str:
    return "{}|{}".format(project or "", re.sub(r"[^\w]|_", "", (title or "").lower()))


def make_id(call: str, owner: str, text: str) -> str:
    raw = "{}|{}|{}".format(call_key(call), (owner or "me").strip().lower(), (text or "").strip().lower())
    return "c-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


def words(s: str) -> set:
    return {w for w in WORD.findall((s or "").lower()) if len(w) > 2}


def similar(a: str, b: str, share: float = 0.6) -> bool:
    x, y = words(a), words(b)
    if not x or not y:
        return (a or "").strip().lower() == (b or "").strip().lower()
    return len(x & y) / min(len(x), len(y)) >= share


def norm_text(s: str) -> str:
    """The window's key of an On me line: lower case, letters and digits, single spaces (feed.js onMe)."""
    return " ".join(re.findall(r"[^\W_]+", (s or "").lower(), re.U))


def path_for(folder) -> Path:
    p = Path(folder)
    return p if p.name == FILE else p / FILE


def read_events(folder) -> List[dict]:
    p = path_for(folder)
    if not p.exists():
        return []
    out = []
    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("op") and e.get("id"):
            out.append(e)
    return out


def fold(events: List[dict]) -> List[dict]:
    """Items in the order they were added, with status open|done|dropped. A duplicate add (same call, similar
    text, rules/commitments.yaml > duplicates) points at the first item; later events on it apply to the first."""
    items: Dict[str, dict] = {}
    alias: Dict[str, str] = {}
    for e in events:
        op, cid = e.get("op"), e.get("id")
        if op == "add":
            if cid in items or cid in alias:
                continue
            twin = next((i for i in items.values() if i["status"] == "open" and call_key(i.get("call")) == call_key(e.get("call"))
                         and (i.get("owner") or "me").lower() == (e.get("owner") or "me").lower() and similar(i["text"], e.get("text", ""))), None)
            if twin:
                alias[cid] = twin["id"]
                continue
            it = {k: e.get(k, "") for k in ("id", "text", "owner", "project", "series", "call", "t", "created", "due", "by")}
            it.update(status="open", done_at="", done_source="", done_call="")
            items[cid] = it
            continue
        it = items.get(alias.get(cid, cid))
        if not it:
            continue
        if op == "done":
            it.update(status="done", done_at=e.get("at", ""), done_source=e.get("source", "manual"), done_call=e.get("call", ""))
        elif op == "reopen":
            it.update(status="open", done_at="", done_source="", done_call="")
        elif op == "drop":
            it["status"] = "dropped"
    return list(items.values())


def load(folder) -> List[dict]:
    return fold(read_events(folder))


def append(folder, events: List[dict]) -> None:
    if not events:
        return
    p = path_for(folder)
    p.parent.mkdir(parents=True, exist_ok=True)
    with _lock, p.open("a", encoding="utf-8") as f:
        for e in events:
            f.write(json.dumps(dict({"v": 1}, **e), ensure_ascii=False) + "\n")


def open_items(folder, series: str = "", limit: int = 15) -> List[dict]:
    """Open items of the project, this series first, newest first inside each group."""
    items = [i for i in load(folder) if i["status"] == "open"]
    items.sort(key=lambda i: (0 if series and i.get("series") == series else 1, _neg(i.get("created", ""))))
    return items[:limit]


def _neg(s: str) -> str:
    return "".join(chr(0x10FFFF - ord(c)) for c in s)


def record_call(folder, *, call: str, project: str, title: str, actions: List[dict], theirs: List[dict],
                ticked: Optional[Dict[str, bool]] = None, by: str = "app") -> List[dict]:
    """End of a call (rules/commitments.yaml > write_when): the PM's actions (owner me) and promises to the PM's
    side (owner = name). `ticked` = the window's On me ticks, by action id. Returns the events written."""
    ticked = ticked or {}       # by action id or by norm_text(what)
    have = load(folder)
    ser = series_key(project, title)
    created = now_iso()
    events = []

    def add(text, owner, due, t, done):
        text = re.sub(r"\s+", " ", str(text or "")).strip()[:120]
        if not text:
            return
        cid = make_id(call, owner, text)
        if any(i["id"] == cid or (call_key(i.get("call")) == call_key(call) and (i.get("owner") or "me").lower() == owner.lower()
                                  and similar(i["text"], text)) for i in have):
            return
        e = {"op": "add", "id": cid, "text": text, "owner": owner, "project": project, "series": ser,
             "call": Path(call).name, "t": t or "", "created": created, "due": str(due or "")[:40], "by": by}
        events.append(e)
        have.append(dict(e, status="open"))
        if done:
            events.append({"op": "done", "id": cid, "at": created, "source": "manual", "call": Path(call).name})

    for a in actions or []:
        add(a.get("what"), "me", a.get("due"), a.get("t"),
            bool(ticked.get(str(a.get("id") or "")) or ticked.get(norm_text(a.get("what") or ""))))
    for a in theirs or []:
        who = str(a.get("who") or "").strip()[:40]
        if who and who.lower() not in ("pm", "me"):
            add(a.get("what"), who, a.get("due"), a.get("t"), False)
    append(folder, events)
    return events


def mark(folder, cid: str, op: str = "done", source: str = "manual", call: str = "") -> dict:
    e = {"op": op, "id": cid, "at": now_iso()}
    if op == "done":
        e["source"] = source
        if call:
            e["call"] = Path(call).name
    append(folder, [e])
    return e


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "done", "reopen", "drop"])
    ap.add_argument("folder", type=Path)
    ap.add_argument("id", nargs="?")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        for i in load(a.folder):
            if a.all or i["status"] == "open":
                print(json.dumps(i, ensure_ascii=False))
        return 0
    if not a.id:
        ap.error("id is required")
    print(json.dumps(mark(a.folder, a.id, a.cmd), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
