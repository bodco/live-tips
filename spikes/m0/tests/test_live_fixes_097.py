"""0.9.7 (owner, call of 11.11): "them" cards on a colleague's line, agenda items discussed but shown "not raised",
and Whisper not knowing the call's terms."""
import json

from livetips_m0 import agenda
from test_presentation_rules import T  # noqa: F401  (module fixture: the recorder)


def test_an_on_them_card_does_not_fire_on_a_colleague(T, tmp_path):
    stem = tmp_path / "call.md"
    (tmp_path / "call.cards.json").write_text(json.dumps([{"id": "price", "triggers": ["how much does it cost"], "on": "them",
                                                           "gist": "Price", "cooldown_s": 0}]))
    tips = tmp_path / "call.tips.jsonl"
    tips.write_text("")
    c = T.Cards(stem, tips)
    sides = {"S1": "team", "S2": "client"}
    T.Cards.side_of_sid = sides.get
    try:
        c.check(T.Line(channel="them", t=1.0, lang="en", text="So how much does it cost per seat?", sid="S1"))
        assert tips.read_text() == ""                               # our colleague asked: no card
        c.check(T.Line(channel="them", t=2.0, lang="en", text="So how much does it cost per seat?", sid="S2"))
        assert '"card": "price"' in tips.read_text()                # the client asked: the card
        c.last.clear()
        c.check(T.Line(channel="them", t=3.0, lang="en", text="how much does it cost", sid=None))
        assert tips.read_text().count('"card": "price"') == 2       # unknown speaker: as before
    finally:
        T.Cards.side_of_sid = None


def test_an_item_that_was_discussed_is_raised_not_todo():
    items = [("Agree the plan", False), ("Who runs the cleanup", False), ("Next call date", False)]
    assert agenda.states(items, set(), -1, {}, {0, 1}) == ["raised", "raised", "todo"]
    assert agenda.states(items, {0}, 1, {}, {0, 1}) == ["done", "now", "todo"]
    assert agenda.states(items, set(), -1, {0: "skip"}, {0}) == ["skip", "todo", "todo"]
    assert agenda.status_label({"state": "raised"}, True) == "піднято"


def test_engine_keeps_raised_items_by_id():
    from livetips_m0.engine import Engine
    e = Engine.__new__(Engine)
    e.agenda_ids, e.agenda_now, e.agenda_manual = ["q1", "q2", "q3"], 1, {}
    assert e._raised_idx() == {1}
    e.agenda_now = -1
    e.agenda_ids = ["q0", "q2", "q3"]                               # a refreshed agenda: q2 moved but stays raised
    assert e._raised_idx() == {1}


def test_whisper_gets_the_terms_of_the_brief(T):
    brief = ("# Live Brief: X\n\n## 5. Names and aliases\n- Emily Carter: Emily, Emely\n- Fireflies (FireFest)\n\n"
             "## 7. Insight Bank\nHubSpot seats; HubSpot Starter; the AI layer over HubSpot; AI notes.\n")
    t = T.glossary_terms(brief)
    assert t[:2] == ["Emily Carter", "Fireflies"] and "HubSpot" in t and "AI" in t
    p = T.with_glossary("Mike and Emily discuss the pilot.", t)
    assert p.startswith("Mike and Emily discuss the pilot. ") and "HubSpot" in p and len(p) < 400
    assert T.with_glossary("x", []) == "x"
