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


def test_commitments_cli_and_fold(tmp_path, capsys):
    from livetips_m0 import commitments as R
    folder = tmp_path / "live"
    ev = R.record_call(folder, call="2026-10-01-1000-weekly.md", project="p", title="Weekly",
                       actions=[{"what": "Send   the deck", "id": "a1"}, {"what": "Book the room"}, {"what": " "}],
                       theirs=[{"who": "Ann", "what": "Review the spec"}, {"who": "PM", "what": "x"}, {"who": "", "what": "y"}],
                       ticked={"a1": True})
    assert [e["op"] for e in ev] == ["add", "done", "add", "add"] and ev[0]["text"] == "Send the deck"
    again = R.record_call(folder, call="2026-10-01-1000-weekly.md", project="p", title="Weekly",
                          actions=[{"what": "send the deck"}], theirs=[], ticked={})
    assert again == []                                    # a similar item of the same call is not added twice
    assert R.main(["list", str(folder)]) == 0
    open_ = [json.loads(l) for l in capsys.readouterr().out.splitlines()]
    assert [i["text"] for i in open_] == ["Book the room", "Review the spec"]
    R.main(["list", str(folder), "--all"])
    assert len(capsys.readouterr().out.splitlines()) == 3
    cid = open_[0]["id"]
    assert R.main(["drop", str(folder), cid]) == 0
    assert json.loads(capsys.readouterr().out)["op"] == "drop"
    R.main(["reopen", str(folder), cid])
    R.main(["done", str(folder), cid])
    capsys.readouterr()
    items = {i["id"]: i for i in R.load(folder)}
    assert items[cid]["status"] == "done" and items[cid]["done_source"] == "manual"
    import pytest
    with pytest.raises(SystemExit):
        R.main(["done", str(folder)])
    (folder / R.FILE).open("a").write("bad\n{\"op\": \"done\"}\n" + json.dumps({"op": "done", "id": "nope"}) + "\n")
    assert len(R.load(folder)) == 3


def test_fold_aliases_a_duplicate_add():
    from livetips_m0.commitments import fold
    ev = [{"op": "add", "id": "a", "text": "send the deck", "call": "c.md"},
          {"op": "add", "id": "a", "text": "again", "call": "c.md"},
          {"op": "add", "id": "b", "text": "send the deck today", "call": "c.app.md"},
          {"op": "done", "id": "b", "at": "t", "source": "said"},
          {"op": "add", "id": "c", "text": "other", "call": "d.md", "owner": "Ann"}]
    items = fold(ev)
    assert [i["id"] for i in items] == ["a", "c"] and items[0]["status"] == "done" and items[0]["done_source"] == "said"


def test_replay_helpers():
    from types import SimpleNamespace as S
    from livetips_m0.replay import select_lines, set_path
    lines = [S(t_s=100.0, dur=None, written=None, seg_end=None), S(t_s=0.0, dur=2.0, written=None, seg_end=None),
             S(t_s=50.0, dur=None, written=300.0, seg_end=None)]
    sel, t0 = select_lines(lines, minutes=2, start_min=0)
    assert t0 == 3.0 and [l.written for l in sel] == [3.0, 104.0]
    assert select_lines([]) == (None, None)
    cfg = {"a": 1}
    set_path(cfg, 'b.c="5m"')
    set_path(cfg, "a=2")
    assert cfg == {"a": 2, "b": {"c": "5m"}}


def test_judge_helpers(tmp_path):
    from types import SimpleNamespace as S
    from livetips_m0.judge import engine_summary, in_call, quick_sample, same_file, shown_tip
    assert shown_tip({"kind": "tip", "src": "s", "at": "a"}, set())
    assert not shown_tip({"kind": "tip", "src": "s", "at": "a", "uid": "u"}, {"u"})
    assert not shown_tip({"kind": "tip", "src": "s", "at": "a", "engine": "skill"}, set(), "skill")
    assert not shown_tip({"kind": "retract"}, set()) and not shown_tip({"kind": "tip", "src": "s", "at": "a", "partial": True}, set())
    f = tmp_path / "t.jsonl"
    f.write_text("")
    assert same_file(f, f) and not same_file(None, f) and not same_file(f, tmp_path / "x")
    lines = [S(written=100.0, t_s=0), S(written=None, t_s=0), S(written=200.0, t_s=0)]
    items = [{"src_s": 30}, {"src_s": 50}, {"src_s": 260}, {"src_s": 261}]
    assert in_call(items, lines) == [{"src_s": 50}, {"src_s": 260}] and in_call(items, []) == items
    many = [{"engine": "app", "at_s": i} for i in range(40)] + [{"engine": "skill", "at_s": i} for i in range(5)]
    q = quick_sample(many)
    assert len(q) == 25 and sum(1 for t in q if t["engine"] == "skill") == 5
    assert engine_summary([])["n"] == 0
    s = engine_summary([{"score": 5, "timely": True}, {"score": 2, "gist": "g", "reason": "r"}])
    assert s["mean"] == 3.5 and s["share_4plus"] == 0.5 and s["timely"] == 0.5 and s["worst"] == ["2 (g): r"]
