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


def test_fact_lines_and_facts_block(tmp_path):
    from livetips_m0.prompt import fact_lines, facts_block
    assert fact_lines(None, "fact") == [] and fact_lines({"facts": "x"}, "fact") == []
    assert fact_lines([{"id": 1, "gist": "G", "phrase": "P", "note": "N"}, "skip"], "card") == ["- [card:1] G | P | N"]
    assert fact_lines({"items": [{"title": "T"}]}, "fact") == ["- [fact:] T |  | "]
    f = tmp_path / "f.json"
    f.write_text('{"facts": [{"id": "a", "title": "T", "text": "x", "source": "s"}]}')
    bad = tmp_path / "bad.json"
    bad.write_text("{")
    assert facts_block(f, bad) == "- [fact:a] T | x | s" and facts_block(None, tmp_path / "none") == ""
    assert facts_block(f, None, limit=5) == "- [fa"


def test_refresh_brief(tmp_path):
    import os
    from livetips_m0.prompt import PromptBuilder
    from livetips_m0.rules import Rules
    rules = Rules()
    brief = tmp_path / "brief.md"
    pb = PromptBuilder(rules, {"title": "T"}, brief_path=brief)
    assert pb._brief == "(no brief)" and pb.refresh_brief() is False
    brief.write_text("")
    assert pb.refresh_brief() is False                    # an empty file is not a brief yet
    brief.write_text("New brief")
    os.utime(brief, (1, 2))
    assert pb.refresh_brief() is True and "New brief" in pb.blocks[1]["text"]
    assert pb.refresh_brief() is False                    # same file, same time
    assert PromptBuilder(rules, {}).refresh_brief() is False


def test_signals_direct_and_hint():
    from livetips_m0.signals import Signals
    assert Signals(commitment=True).route == "direct" and Signals(commitment=True).trigger_hint == "pm_commitment"
    assert Signals(new_requirement=True, third_person=True).direct
    assert Signals(name_vocative=True, update_request=True).route == "direct"
    assert Signals(name_vocative=True, question=True, third_person=True).route == "classify"
    assert Signals(question=True, second_person=True).direct and not Signals(question=True).direct
    assert Signals(frustration=True).route == "classify" and Signals().route is None
    assert Signals(name_mention=True).trigger_hint == "your_turn"
    assert Signals(name_mention=True, question=True).trigger_hint == "direct_question"
    assert Signals(name_mention=True, question=True, update_request=True).trigger_hint == "your_turn"
    assert Signals(frustration=True).trigger_hint == "frustration" and Signals().trigger_hint == "none"


def test_context_parts(tmp_path):
    from livetips_m0 import context
    assert context.hits_part([]) == ""
    hp = context.hits_part([{"rel": "a.md", "date": "2026-10-01", "preview": "x\ny"}, {"path": "/b", "text": "t"}])
    assert hp.splitlines()[1:] == ["- [a.md, 2026-10-01] x y", "- [/b] t"]
    ws = tmp_path / "Acme General"
    for name in ("Acme General", "Alpha", "Beta", "_hidden"):
        (tmp_path / name / "_notion").mkdir(parents=True)
        (tmp_path / name / "_notion" / "current-state.md").write_text("state of " + name)
    (ws / "_notion" / "current-state.md").unlink()
    assert context.workspace_bases(ws) == [ws, tmp_path]
    part = context.state_part(ws)
    assert "WORKSPACE PROJECTS" in part and "[Alpha]" in part and "[Beta]" in part and "_hidden" not in part
    assert context.state_part(tmp_path / "Alpha").startswith("PROJECT CURRENT STATE")
    assert context.project_dirs(tmp_path / "none") == [] and context.state_part(tmp_path / "none") == ""
