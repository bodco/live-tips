"""0.12.3: the engine reads Decisions, Tasks and Risks by the call page's one rule (call_lists = CallLists.swift).
The cases mirror CoreChecks callLists0122, so the two readings cannot drift apart unnoticed."""
import json
from pathlib import Path

from livetips_m0 import call_lists, pn_tools
from livetips_m0.call_lists import resolve
from livetips_m0.decision_notion import call_decisions
from livetips_m0.risk_notion import call_risks

LIVE = {"kind": "situation", "decisions": ["Ship on Friday", "Немає."],
        "actions": [{"what": "Send the deck", "due": "Monday", "t": "10:05:00"}],
        "theirs": [{"who": "Mike", "what": "Share the budget"}], "risks": [{"what": "Budget not approved"}]}
MN = ("# Call notes\n\n## Meeting notes\n\n### TL;DR\nShort.\n\n### Decisions\n- [10:01:00] **Go with plan B**\n- Go with plan B\n\n"
      "### Action items\n- **Emily**: draft the contract (due: Friday)\n- **Mike:** review the draft\n- Book the room\n\n"
      "### Risks\n- Vendor may slip\n\n## Decisions\n- Old decision\n")
EDIT_RISKS = dict(LIVE, source="call_page", lists=["risks"], risks=[{"what": "Legal review"}])
EDIT_ALL = dict(LIVE, source="call_page", decisions=[], risks=[])


def test_live_picture():
    r = resolve([LIVE], None)
    assert r["decisions"] == ["Ship on Friday"] and r["decisions_from"] == "live"
    assert r["risks"] == ["Budget not approved"] and r["risks_from"] == "live"
    t = r["tasks"]
    assert len(t) == 2 and t[0]["mine"] is True and t[0]["due"] == "Monday" and t[1]["owner"] == "Mike" and t[1]["mine"] is False
    assert call_lists.task_line(t[1]) == "Mike: Share the budget"


def test_notes_beat_live():
    r = resolve([LIVE], MN)
    assert r["decisions"] == ["Go with plan B"] and r["decisions_from"] == "notes"
    assert [i["t"] for i in r["decision_items"]] == ["10:01:00"]
    assert r["risks"] == ["Vendor may slip"] and r["risks_from"] == "notes"
    t = r["tasks"]
    assert r["tasks_from"] == "notes" and len(t) == 3
    assert (t[0]["owner"], t[0]["text"], t[0]["due"], t[0]["mine"]) == ("Emily", "draft the contract", "Friday", None)
    assert (t[1]["owner"], t[1]["text"]) == ("Mike", "review the draft")
    assert (t[2]["owner"], t[2]["text"]) == ("", "Book the room")


def test_nothing_notes_fall_through():
    empty = "## Meeting notes\n\n### Decisions\n- Жодних рішень не приймалося.\n\n### Action items\n- None\n"
    r = resolve([LIVE], empty)
    assert (r["decisions_from"], r["tasks_from"], r["risks_from"]) == ("live", "live", "live")


def test_pm_edit():
    r = resolve([LIVE, EDIT_RISKS], MN)
    assert r["risks"] == ["Legal review"] and r["risks_from"] == "pm"
    assert r["decisions"] == ["Go with plan B"] and r["decisions_from"] == "notes", "a risks edit does not freeze decisions"
    r = resolve([LIVE, EDIT_ALL], MN)
    assert r["decisions"] == [] and r["decisions_from"] == "pm" and r["risks"] == [] and r["risks_from"] == "pm"
    r = resolve([LIVE, EDIT_ALL, {"kind": "situation", "decisions": ["Later live"]}], None)
    assert r["decisions_from"] == "pm", "a live line after the edit does not undo it"


def test_legacy_and_nothing():
    old = "# Call notes\n## Summary\nx\n## Decisions\n- **Keep the old API**\n- None\n## Action items\n- **Mike**: send notes\n## Concerns and mood\n- calm\n"
    r = resolve([], old)
    assert r["decisions"] == ["Keep the old API"] and r["decisions_from"] == "legacy"
    assert r["tasks"][0]["owner"] == "Mike" and r["tasks_from"] == "legacy" and r["risks"] == [] and r["risks_from"] == "none"
    r = resolve([], None)
    assert r["decisions"] == r["tasks"] == r["risks"] == [] and r["decisions_from"] == "none"


def _call(tmp_path: Path, situations, notes=MN, sub: str = "") -> Path:
    if sub:
        tmp_path = tmp_path / sub
        tmp_path.mkdir()
    md = tmp_path / "2026-11-15-1000-sync.app.md"
    md.write_text("# Live transcript: Sync\n- Start: 10:00\n\n[10:00:01] Mike: hello\n", encoding="utf-8")
    lines = ['{"kind":"tip","text":"x"}'] + [json.dumps(s) for s in situations]
    Path(str(md) + ".tips.jsonl").write_text("\n".join(lines), encoding="utf-8")
    if notes is not None:
        (tmp_path / "2026-11-15-1000-sync.app.notes.md").write_text(notes, encoding="utf-8")
    return md


def test_read_files(tmp_path):
    r = call_lists.read(_call(tmp_path, [LIVE, EDIT_RISKS]))
    assert (r["decisions_from"], r["risks_from"], r["tasks_from"]) == ("notes", "pm", "notes")


def test_auto_add_reads_the_rule(tmp_path):
    md = _call(tmp_path, [LIVE, EDIT_RISKS])
    assert call_decisions(md) == ["Go with plan B"], "notes decisions, not the last situation's"
    assert call_risks(md) == ["Legal review"], "the PM's risks edit"
    md2 = _call(tmp_path, [LIVE, EDIT_ALL], notes=None, sub="b")
    assert call_decisions(md2) == [] and call_risks(md2) == [], "the PM removed everything: nothing is added"


def test_pn_tools_reads_the_rule(tmp_path):
    md = _call(tmp_path, [LIVE, EDIT_ALL])
    src, rows = pn_tools.call_facts(md)
    assert "call page edit" in src
    assert not [r for r in rows if r[0] == "decision"], "the PM removed the decisions"
    assert [r[2] for r in rows if r[0] == "promise"] == ["Emily: draft the contract (due: Friday)", "Mike: review the draft", "Book the room"]
    md = _call(tmp_path, [LIVE], notes=None, sub="c")
    src, rows = pn_tools.call_facts(md)
    assert src.startswith("call picture")
    assert [r[2] for r in rows if r[0] == "promise"] == ["PM: Send the deck (due: Monday)", "Mike: Share the budget"]
    assert [r[2] for r in rows if r[0] == "decision"] == ["Ship on Friday"]
