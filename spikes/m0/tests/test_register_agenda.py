"""Pacenote 0.8 (F5): the commitments register (rules/commitments.yaml) and the agenda (rules/agenda.yaml)."""
import json
import time

from livetips_m0 import agenda, commitments as reg
from test_engine import _feed, _meeting_engine, _out


def test_register_fold_duplicates_and_events(tmp_path):
    reg.record_call(tmp_path, call="/x/live/call-1.app.md", project="orbit", title="Weekly sync",
                    actions=[{"id": "m1", "what": "Send the test account list", "due": "Friday"}],
                    theirs=[{"who": "Dana", "what": "share the export spec", "due": ""}], ticked={}, by="app")
    # the skill recorded the same call: the same items in other words are duplicates
    reg.append(tmp_path, [{"op": "add", "id": reg.make_id("call-1.md", "me", "send test account list"), "text": "send test account list",
                           "owner": "me", "project": "orbit", "series": reg.series_key("orbit", "Weekly sync"), "call": "call-1.md", "by": "skill"}])
    items = reg.load(tmp_path)
    assert len(items) == 2 and {i["owner"] for i in items} == {"me", "Dana"}
    mine = next(i for i in items if i["owner"] == "me")
    assert mine["series"] == "orbit|weeklysync" and mine["due"] == "Friday"
    reg.mark(tmp_path, mine["id"], "done", source="detected", call="call-2.app.md")
    assert [i["status"] for i in reg.load(tmp_path) if i["owner"] == "me"] == ["done"]
    reg.mark(tmp_path, mine["id"], "reopen")
    assert [i["id"] for i in reg.open_items(tmp_path, series="orbit|weeklysync")][0] in {mine["id"], items[1]["id"]}
    # the same call recorded again adds nothing
    again = reg.record_call(tmp_path, call="/x/live/call-1.md", project="orbit", title="Weekly sync",
                            actions=[{"id": "m1", "what": "Send the test account list"}], theirs=[], by="skill")
    assert again == []


def test_register_ticked_item_is_added_closed(tmp_path):
    ev = reg.record_call(tmp_path, call="c.app.md", project="p", title="T",
                         actions=[{"id": "m1", "what": "Book the demo room"}], theirs=[], ticked={"m1": True})
    assert [e["op"] for e in ev] == ["add", "done"] and reg.load(tmp_path)[0]["status"] == "done"


def test_agenda_from_brief_and_states():
    brief = "## Checklist\n- [ ] Release date\n- [x] **Export** spec\n- [ ] [Budget](http://x) for Q1\n- plain line\n"
    items = agenda.from_brief(brief)
    assert items == [("Release date", False), ("Export spec", True), ("Budget for Q1", False)]
    assert agenda.states(items, {2}, 0, {}) == ["now", "done", "done"]
    assert agenda.states(items, set(), 0, {2: "now"}) == ["todo", "done", "now"]


def test_engine_agenda_theirs_done_card_and_register(tmp_path):
    brief = "- [ ] Release date\n- [ ] Export spec\n"
    reg.append(tmp_path, [{"op": "add", "id": "c-old", "text": "Send the invoice", "owner": "me", "project": "", "series": "|x",
                           "call": "old.md", "created": "2026-10-01T10:00:00+00:00"}])

    def resp(model, user):
        if "PREVIOUS STATE" in user:
            assert "AGENDA:" in user and "c-old" in user
            return ('{"topic": "release", "owner": "Dana", "mine": false, "floor": "Dana", "asks": [], '
                    '"actions": [{"id": "m1", "what": "check the release notes", "due": "Monday"}], "decisions": [], "speech_done": [], '
                    '"agenda_now": 1, "agenda_done": [0], "theirs": [{"who": "Dana", "what": "send the export spec", "due": "Friday"}], '
                    '"done_commitments": ["c-old"]}')
        return '{"need_tip": false, "level": "none", "trigger": "none", "topic": "x"}'
    eng, clock = _meeting_engine(tmp_path, resp, situation=True, proactive=False, register_dir=str(tmp_path),
                                 call_file=str(tmp_path / "call-9.app.md"))
    assert eng.open_commitments and eng.open_commitments[0]["id"] == "c-old"
    eng.set_agenda_items(brief)
    _feed(eng, clock, "[10:00:05] Other (en): The release date is fine. Now the export spec, I will send it by Friday.", 1, 36005.0)
    tips, _ = _out(tmp_path)
    ag = [t for t in tips if t.get("kind") == "agenda"]
    assert ag[-1]["items"][0]["done"] and ag[-1]["items"][1]["cur"]
    card = [t for t in tips if t.get("kind") == "commitment_done"]
    assert len(card) == 1 and card[0]["id"] == "c-old" and "Done?" in card[0]["gist"]
    eng.set_agenda_state("a1|done")
    assert eng.agenda_strip()[1]["state"] == "done"
    eng.onme_ticked[reg.norm_text("Check the release-notes")] = False
    eng.onme_ticked[reg.norm_text("check the release notes")] = True
    eng.final_wrapup()
    items = {i["text"]: i for i in reg.load(tmp_path)}
    assert items["check the release notes"]["status"] == "done" and items["send the export spec"]["owner"] == "Dana"
    assert items["Send the invoice"]["status"] == "open"          # a detected close is only a proposal
    tips, _ = _out(tmp_path)
    assert [t for t in tips if t.get("kind") == "agenda"][-1].get("final") is True


def test_last_agenda_from_tips_and_labels(tmp_path):
    p = tmp_path / "c.md.tips.jsonl"
    p.write_text(json.dumps({"kind": "agenda", "items": [{"text": "A", "done": True}, {"text": "B", "done": False}]}) + "\n")
    last = agenda.last_from_tips(p)
    assert [agenda.status_label(i, False) for i in last] == ["discussed", "not raised"]


def test_notion_wrapup_has_the_agenda_section(tmp_path):
    from livetips_m0.wrapup_notion import wrapup_blocks
    md = tmp_path / "call.md"
    md.write_text("# Live transcript: X\n")
    (tmp_path / "call.md.tips.jsonl").write_text(json.dumps({"kind": "agenda", "items": [
        {"text": "Release date", "done": True}, {"text": "Export", "cur": True}, {"text": "Budget"}]}) + "\n")
    b = wrapup_blocks({"decisions": ["ship"]}, {}, md, False, "en")
    text = json.dumps(b)
    assert "Agenda" in text and "Release date: discussed" in text and "Export: raised" in text and "Budget: not raised" in text


def test_register_link_unlink_and_from(tmp_path):
    """0.8.6 (rules/commitments.yaml): link to a Notion task, unlink when the page is removed, from for "Mine"."""
    reg.append(tmp_path, [{"op": "add", "id": "c-a", "text": "Send the Orbit plan", "owner": "me", "call": "x.md", "from": "c-b"}])
    reg.mark(tmp_path, "c-a", "link", notion_page="p-1")
    it = reg.load(tmp_path)[0]
    assert it["notion_page"] == "p-1" and it["from"] == "c-b"
    reg.mark(tmp_path, "c-a", "unlink", source="removed")
    it = reg.load(tmp_path)[0]
    assert it["notion_page"] == "" and it["notion_note"] == "removed" and it["status"] == "open"
    reg.mark(tmp_path, "c-a", "done", source="notion")
    assert reg.load(tmp_path)[0]["done_source"] == "notion"


def test_mine_makes_a_line_the_pms(tmp_path):
    """0.8.6 > mine: the raw line shows at once; the call picture's wording (from = mine<n>) replaces it; an earlier
    "on them" item gets a drop and the new add carries from."""
    from types import SimpleNamespace
    from livetips_m0.engine import Engine
    eng = SimpleNamespace(onme_mine=[], onme_fixed={})
    eng.add_mine = Engine.add_mine.__get__(eng)
    eng.fix_onme = Engine.fix_onme.__get__(eng)
    eng.add_mine("Emily Clark: we still need the Orbit invoice sent", "c-old", "Send the Orbit invoice")
    sit = eng.fix_onme({"actions": [], "theirs": [{"who": "Ann Lee", "what": "Send the Orbit invoice"}]})
    assert sit["actions"][0]["what"].startswith("Emily Clark") and sit["theirs"] == []
    sit = eng.fix_onme({"actions": [{"id": "m1", "what": "Send the Orbit invoice", "from": "mine1"}], "theirs": []})
    assert [a["what"] for a in sit["actions"]] == ["Send the Orbit invoice"]
    reg.append(tmp_path, [{"op": "add", "id": "c-old", "text": "Send the Orbit invoice", "owner": "Ann Lee", "call": "a.md"}])
    reg.record_call(tmp_path, call="b.md", project="orbit", title="Sync", actions=sit["actions"], theirs=[],
                    replaces={"mine1": "c-old"})
    items = {i["id"]: i for i in reg.load(tmp_path)}
    assert items["c-old"]["status"] == "dropped"
    mine = [i for i in items.values() if i["owner"] == "me"][0]
    assert mine["from"] == "c-old"
