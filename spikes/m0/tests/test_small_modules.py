"""Small helpers pinned before the ub-mode pass: the spend ledger, call files, call memory passages."""
import json
from pathlib import Path

from livetips_m0 import callinfo, memory
from livetips_m0.cost import BudgetGuard


def test_budget_ledger(tmp_path):
    led = tmp_path / "d" / "spend.json"
    g = BudgetGuard(str(led), 1.0, 2.0, 3.0)
    assert g.month_spent() == 0.0 and g.state() == "ok"
    g.add(0.6)
    g.add(None)
    g.add(0.5)
    assert g.call_spent == 1.1 and g.state() == "soft" and abs(g.month_spent() - 1.1) < 1e-9
    led.write_text("{bad")
    assert g.month_spent() == 0.0
    g.add(0.25)
    assert json.loads(led.read_text()) == {g._month(): 0.25}
    g.add(1.0)
    assert g.state() == "hard"
    h = BudgetGuard(str(led), 10, 10, 1.0)
    assert h.state() == "hard"                      # the month is over its cap


def write_call(root: Path, name: str, lines, title="Weekly"):
    live = root / "live"
    live.mkdir(parents=True, exist_ok=True)
    md = live / name
    md.write_text("# Live transcript: " + title + "\n- Start: 10:00\n- Project: demo-proj\n\n" + "\n".join(lines) + "\n")
    return md


def test_callinfo_items_and_header(tmp_path):
    md = write_call(tmp_path, "2026-10-01-1000-weekly.md", ["[10:00:01] Me (en): hello there"])
    Path(str(md) + ".tips.jsonl").write_text('{"kind": "risk", "what": "a"}\nnot json "risk"\n{"kind": "tip", "gist": "risk"}\n')
    Path(callinfo.stem_of(md) + ".tips.jsonl").write_text('{"kind": "risk", "what": "b"}\n')
    assert [o["what"] for o in callinfo.items_of_kind(md, "risk")] == ["a", "b"]
    assert callinfo.last_item(md, "risk")["what"] == "b" and callinfo.last_item(md, "agenda") is None
    assert callinfo.header(md) == {"title": "Weekly", "start": "10:00", "project": "demo-proj"}
    assert callinfo.transcript_text(md) == "[10:00:01] Me: hello there"


def test_memory_passages(tmp_path, monkeypatch):
    root = tmp_path / "proj"
    a = write_call(root, "2026-10-02-1000-sync.md", ["[10:00:01] Me (en): the CSV export ships Friday",
                                                     "[10:00:09] Other (en): good, the report needs it"])
    write_call(root, "2026-10-02-1000-sync.app.md", ["[10:00:01] Me (en): duplicate of the same call"])
    write_call(root, "2026-10-01-0900-old.md", ["[09:00:01] Other (en): nothing here"])
    (root / "live" / "notes.md").write_text("not a call")
    assert [p.name for p in memory.transcripts(root)] == ["2026-10-02-1000-sync.md", "2026-10-01-0900-old.md"]
    assert memory.transcripts(tmp_path / "none") == []
    hits = [{"path": str(a), "preview": "the CSV export ships Friday and more"},
            {"path": "live/2026-10-01-0900-old.md", "text": "unknown words"},
            {"path": str(root / "notes.md"), "preview": "x"}, {"path": "live/2026-10-02-1000-sync.md", "preview": "y"}]
    monkeypatch.setattr(memory, "index_snippets", lambda lt, r, q, k, timeout: hits)
    ps = memory.index_passages(root, "csv", ["py", "lt"], k=2)
    assert [(p["file"].name, p["t"]) for p in ps] == [("2026-10-02-1000-sync.md", "10:00:01"), ("2026-10-01-0900-old.md", "")]
    assert memory.word_passages(root, "a b") == []
    wp = memory.word_passages(root, "report CSV")
    assert wp and wp[0]["file"] == a and wp[0]["t"] == "10:00:01"


def test_memory_answer_parts(tmp_path):
    root = tmp_path / "proj"
    md = write_call(root, "2026-10-02-1000-sync.md", ["[10:00:01] Me (en): the CSV export ships Friday",
                                                      "[10:00:09] Other (en): Good, the report needs it"])
    ps = [{"file": md, "t": "10:00:01", "text": "p0"}, {"file": md, "t": "10:00:09", "text": "p1"}]
    assert memory.best_passage(ps, {"passage": 1}) is ps[1]
    assert memory.best_passage(ps, {"passage": 7}) is ps[0] and memory.best_passage(ps, {"passage": "x"}) is ps[0]
    assert memory.passages_prompt("q?", ps[:1]) == 'QUESTION: q?\n\nPASSAGE 0 (call "Weekly", 2026-10-02):\np0'
    assert memory.moment(md, lambda t: "report" in t) == "10:00:09" and memory.moment(md, lambda t: False, "d") == "d"
    assert memory.call_file(root, "live/2026-10-02-1000-sync.md") == md and memory.call_file(root, None) is None
